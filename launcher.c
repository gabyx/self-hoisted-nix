/*
 * =============================================================================
 * self-hoisted-nix launcher
 * =============================================================================
 *
 * This program is the first part of every bundle built by erofs-bundle.nix.
 * A finished bundle is ONE file:
 *
 *   byte 0 ..            this launcher, a fully static (musl) ELF executable,
 *                        padded with NUL bytes to a 4 KiB boundary
 *   image-offset ..      an EROFS filesystem image whose root directory is the
 *                        program's whole runtime closure, i.e. what would
 *                        normally live under /nix/store
 *   last 4096 bytes      a small text trailer, for example:
 *
 *                          self-hoisted-nix v1
 *                          image-offset 2334720
 *                          image-size 21233664
 *                          exec /nix/store/<hash>-jq-1.8.2-bin/bin/jq
 *
 *                        padded with NUL bytes. `tail -c 4096 bundle` shows it.
 *
 * Because the launcher sits at byte 0, the bundle itself IS the executable:
 * the kernel's ELF loader only maps the ranges named in the ELF program
 * headers and never looks at the image and trailer that follow. So nothing
 * has to be extracted, copied into a memfd, or written to disk. The launcher
 * is generic; it is compiled once and every bundle just appends a different
 * image and trailer to it.
 *
 * The launcher contains everything that used to be three separate programs
 * (a shell stub, bwrap and erofsfuse):
 *
 *   - the namespace and mount setup that bwrap used to do, written out below;
 *   - erofs-utils' complete FUSE server, linked in as a static library
 *     (liberofsfuse.a, built with --enable-static-fuse, which renames its
 *     main() to erofsfuse_main()).
 *
 * What happens when you run a bundle, and which process does what:
 *
 *   OUTER    The process you started. It reads the trailer, creates new user,
 *            mount and PID namespaces, and forks INIT. Then it just waits,
 *            forwards signals, and finally exits exactly the way the program
 *            did.
 *
 *   INIT     PID 1 of the new PID namespace. It builds a new root filesystem
 *            that looks like the host's, except /nix/store is an empty
 *            directory. It then forks FUSE, waits until /nix/store is
 *            mounted, forks PROGRAM, and waits for PROGRAM to exit.
 *
 *   FUSE     Runs erofsfuse_main(), which mounts the EROFS image straight out
 *            of the bundle file (at image-offset) onto /nix/store and serves
 *            it until it is killed.
 *
 *   PROGRAM  exec()s the real program. Every /nix/store/... path baked into
 *            it (ELF interpreter, shared libraries, data files) now resolves.
 *
 * When PROGRAM exits, INIT reports its wait status to OUTER and exits. When
 * PID 1 of a PID namespace exits, the kernel SIGKILLs every other process in
 * it, including FUSE, and the mount namespace (and with it the FUSE mount)
 * disappears. Nothing is left behind on the host.
 *
 * Exit status: the bundle exits with the program's exit status, or dies of
 * the same signal. If the launcher itself cannot set things up, it prints a
 * message starting with "self-hoisted-nix:" and exits with 127, the
 * conventional "could not run the command" status.
 * =============================================================================
 */

/* Needed for unshare(), pipe2(), CLONE_* flags and other Linux extensions. */
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/*
 * erofs-utils' FUSE server. In a normal erofs-utils build this is the main()
 * of the `erofsfuse` program; --enable-static-fuse compiles the same file
 * with -Dmain=erofsfuse_main so that another program (this one) can call it.
 * It takes the usual erofsfuse command line.
 */
int erofsfuse_main(int argc, char *argv[]);

/* Size of the trailer at the end of the bundle, and its first line. */
#define TRAILER_SIZE 4096
#define TRAILER_MAGIC "self-hoisted-nix v1\n"

/* Exit status for "the launcher could not start the program". */
#define EXIT_LAUNCH_FAILED 127

/*
 * Signals that someone might deliberately send to the bundle, for example
 * `kill <pid>`, `timeout`, or a service manager. These are passed on to the
 * program; see forward_signal() for the details.
 */
static const int forwarded_signals[] = {
	SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2,
};
#define N_FORWARDED (sizeof(forwarded_signals) / sizeof(forwarded_signals[0]))

/* -----------------------------------------------------------------------------
 * Error reporting
 * -------------------------------------------------------------------------- */

/*
 * Print "self-hoisted-nix: <message>" and exit with EXIT_LAUNCH_FAILED.
 * If `with_errno` is set, the text for the current errno is appended, like
 * perror() does. _exit() rather than exit(): several of the processes that
 * call this are forked copies, and exit() would also flush stdio buffers
 * they inherited from OUTER, printing the same output twice.
 */
static void vfail(int with_errno, const char *fmt, va_list ap)
{
	int saved = errno;

	fputs("self-hoisted-nix: ", stderr);
	vfprintf(stderr, fmt, ap);
	if (with_errno)
		fprintf(stderr, ": %s", strerror(saved));
	fputc('\n', stderr);
	_exit(EXIT_LAUNCH_FAILED);
}

/* Fail with a message and the errno text, e.g. "cannot open x: No such file". */
static void die_errno(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfail(1, fmt, ap);
}

/* Fail with just a message. */
static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfail(0, fmt, ap);
}

/* Print a warning with the errno text, and carry on. */
static void warn_errno(const char *fmt, ...)
{
	int saved = errno;
	va_list ap;

	fputs("self-hoisted-nix: warning: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, ": %s\n", strerror(saved));
}

/* -----------------------------------------------------------------------------
 * Small I/O helpers
 * -------------------------------------------------------------------------- */

/* Write a short string to a file, e.g. "1001 1001 1\n" to /proc/self/uid_map. */
static void write_file(const char *path, const char *content)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	size_t len = strlen(content);

	if (fd < 0)
		die_errno("cannot open %s", path);
	/*
	 * The /proc files we write here must be written in a single write()
	 * call; the kernel does not accept a mapping split across writes.
	 */
	if (write(fd, content, len) != (ssize_t)len)
		die_errno("cannot write %s", path);
	close(fd);
}

/*
 * Read exactly `len` bytes at `offset`. pread() may return fewer bytes than
 * asked for, or be interrupted by a signal (EINTR), so loop until done.
 */
static void pread_full(int fd, void *buf, size_t len, off_t offset)
{
	char *p = buf;

	while (len > 0) {
		ssize_t n = pread(fd, p, len, offset);

		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			die_errno("cannot read the bundle");
		if (n == 0)
			die("the bundle is truncated");
		p += n;
		len -= (size_t)n;
		offset += n;
	}
}

/* -----------------------------------------------------------------------------
 * Step 1 (OUTER): find out what this bundle contains
 * -------------------------------------------------------------------------- */

struct bundle {
	uint64_t image_offset;  /* where the EROFS image starts, in bytes */
	uint64_t image_size;    /* how long it is, in bytes */
	char exec[PATH_MAX];    /* program to run, a /nix/store/... path */
};

/*
 * Parse the text trailer in the last TRAILER_SIZE bytes of the bundle.
 *
 * Why a trailer at the END rather than values compiled into the launcher?
 * The launcher is built once, generically. Each bundle is made by simply
 * concatenating launcher + image + trailer, so the launcher has to discover
 * where its image is at run time. The end of the file is the one place it
 * can always find without knowing anything else.
 */
static void read_trailer(int self_fd, struct bundle *b)
{
	char buf[TRAILER_SIZE + 1];
	struct stat st;
	char *line, *save;

	if (fstat(self_fd, &st) < 0)
		die_errno("cannot stat the bundle");
	if (st.st_size < TRAILER_SIZE)
		die("this launcher has no bundle attached (file too small)");

	pread_full(self_fd, buf, TRAILER_SIZE, st.st_size - TRAILER_SIZE);
	/* The padding is NUL bytes, but make sure the text is terminated. */
	buf[TRAILER_SIZE] = '\0';

	if (strncmp(buf, TRAILER_MAGIC, strlen(TRAILER_MAGIC)) != 0)
		die("this launcher has no bundle attached (no trailer found)");

	memset(b, 0, sizeof(*b));

	/*
	 * Each line after the magic is "<key> <value>". strtok_r splits the
	 * buffer at newlines, writing a NUL over each one as it goes. It stops
	 * at the first NUL byte, which is where the padding starts.
	 */
	for (line = strtok_r(buf + strlen(TRAILER_MAGIC), "\n", &save); line;
	     line = strtok_r(NULL, "\n", &save)) {
		if (strncmp(line, "image-offset ", 13) == 0)
			b->image_offset = strtoull(line + 13, NULL, 10);
		else if (strncmp(line, "image-size ", 11) == 0)
			b->image_size = strtoull(line + 11, NULL, 10);
		else if (strncmp(line, "exec ", 5) == 0)
			snprintf(b->exec, sizeof(b->exec), "%s", line + 5);
		/* Unknown keys are ignored, so later versions can add some. */
	}

	/*
	 * Sanity checks, so a damaged file fails with a clear message instead
	 * of a confusing FUSE error. The image has to start after the launcher
	 * (offset > 0) and end before the trailer.
	 */
	if (b->exec[0] != '/')
		die("bundle trailer has no valid \"exec\" line");
	if (b->image_offset == 0 || b->image_size == 0 ||
	    b->image_offset + b->image_size >
		    (uint64_t)st.st_size - TRAILER_SIZE)
		die("bundle trailer has an invalid image offset or size");
}

/* -----------------------------------------------------------------------------
 * Signal forwarding (used by OUTER and INIT)
 * -------------------------------------------------------------------------- */

/*
 * The process that forward_signal() passes signals on to. For OUTER this is
 * INIT; for INIT it is PROGRAM. 0 means "nobody yet".
 *
 * `volatile sig_atomic_t` is the type C guarantees a signal handler can read
 * safely. pid_t fits in it on Linux (both are int).
 */
static volatile sig_atomic_t forward_to;

/*
 * Pass a signal on, but only if a process sent it on purpose.
 *
 * Why the si_code check: when you press Ctrl-C, Ctrl-\ or close the terminal,
 * the kernel sends the signal to EVERY process in the terminal's foreground
 * process group. OUTER, INIT and PROGRAM are all in that group, so PROGRAM
 * already gets the signal directly. If we forwarded those as well, PROGRAM
 * would get two or three copies (think of Python printing a second
 * KeyboardInterrupt traceback).
 *
 * Signals generated by the kernel have si_code > 0 (SI_KERNEL). Signals sent
 * by a process with kill(), sigqueue() or tgkill() have si_code <= 0 (SI_USER,
 * SI_QUEUE, SI_TKILL). So we forward only the latter.
 *
 * Known limitation: a process that signals the whole process group at once
 * (`kill -TERM -<pgid>`, or systemd stopping a service) reaches PROGRAM
 * directly AND through us, so PROGRAM may see the signal more than once.
 * For SIGTERM that is harmless for practically every program.
 */
static void forward_signal(int sig, siginfo_t *si, void *ucontext)
{
	(void)ucontext;

	if (si->si_code > 0)
		return;
	if (forward_to > 0)
		kill((pid_t)forward_to, sig);
}

/*
 * Install forward_signal() for every signal in forwarded_signals.
 *
 * SA_SIGINFO: call the three-argument handler so we get si_code.
 * SA_RESTART: restart interrupted system calls (waitpid, read) automatically
 *             where the kernel allows, instead of failing them with EINTR.
 *             We still handle EINTR everywhere, to be safe.
 */
static void install_forwarders(void)
{
	struct sigaction sa;
	size_t i;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = forward_signal;
	sa.sa_flags = SA_SIGINFO | SA_RESTART;
	sigemptyset(&sa.sa_mask);
	for (i = 0; i < N_FORWARDED; i++)
		sigaction(forwarded_signals[i], &sa, NULL);
}

/* Put the forwarded signals back to their default action. */
static void reset_forwarders(void)
{
	size_t i;

	for (i = 0; i < N_FORWARDED; i++)
		signal(forwarded_signals[i], SIG_DFL);
}

/* -----------------------------------------------------------------------------
 * Step 3 (INIT): build the new root filesystem
 * -------------------------------------------------------------------------- */

/* pivot_root has no libc wrapper in musl, so call the system call directly. */
static int pivot_root(const char *new_root, const char *put_old)
{
	return (int)syscall(SYS_pivot_root, new_root, put_old);
}

/*
 * Make "/" a copy of the host's root, except that /nix/store is an empty
 * directory for the FUSE mount and /proc belongs to our new PID namespace.
 *
 * We cannot simply create /nix/store on the host (that needs root, and would
 * change the host). We cannot mount our store over an existing host /nix
 * either, because many hosts have no /nix at all and we cannot create it. So,
 * like bwrap, we build a brand-new root on a tmpfs and bind-mount each of the
 * host's top-level directories into it, one by one.
 *
 * This is all allowed without root because we are inside our own user
 * namespace (where we hold every capability) and our own mount namespace
 * (so none of these mounts are visible to, or affect, the host).
 */
static void setup_root(void)
{
	char src[PATH_MAX], dst[PATH_MAX], target[PATH_MAX];
	struct dirent *de;
	struct stat st;
	DIR *dir;
	ssize_t n;

	/*
	 * A new mount namespace starts as a copy of the host's, and by default
	 * mounts can still "propagate" between the copies (mount something in
	 * one, it appears in the other). Mark everything private first so none
	 * of the mounts below can leak out to the host. pivot_root() also
	 * refuses to work with shared mounts.
	 */
	if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
		die_errno("cannot make mounts private");

	/*
	 * We need an empty directory to build the new root in, but the host's
	 * filesystem is not writable for us. So mount a small tmpfs over /tmp
	 * (only in our namespace; the host's /tmp is untouched, and we will
	 * get it back in a moment) and work in there:
	 *
	 *   /tmp          tmpfs "base"; will briefly become our root
	 *   /tmp/newroot  another tmpfs; will become the final root
	 *   /tmp/oldroot  empty directory; the host root will be moved here
	 *
	 * MS_NOSUID / MS_NODEV: no setuid binaries and no device nodes on these
	 * tmpfs mounts; we never need either there.
	 */
	if (mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755") < 0)
		die_errno("cannot mount a tmpfs on /tmp");
	if (mkdir("/tmp/newroot", 0755) < 0 || mkdir("/tmp/oldroot", 0755) < 0)
		die_errno("cannot create directories in /tmp");
	if (mount("tmpfs", "/tmp/newroot", "tmpfs", MS_NOSUID | MS_NODEV,
		  "mode=0755") < 0)
		die_errno("cannot mount the new root tmpfs");

	/*
	 * First pivot: make the base tmpfs our root and move the host root to
	 * /oldroot. A side effect we rely on: the base tmpfs is no longer
	 * mounted on the host's /tmp, so /oldroot/tmp shows the real host /tmp
	 * again and can be bind-mounted like everything else.
	 */
	if (pivot_root("/tmp", "/tmp/oldroot") < 0)
		die_errno("cannot pivot into the build area");
	if (chdir("/") < 0)
		die_errno("cannot chdir to /");

	/*
	 * Recreate each top-level entry of the host root in /newroot.
	 * We skip:
	 *   .  ..  directory entries for itself and its parent
	 *   nix    replaced by our own /nix/store (on a Nix host, the host
	 *          store is hidden inside the sandbox)
	 *   proc   mounted fresh below, to match our new PID namespace
	 */
	dir = opendir("/oldroot");
	if (!dir)
		die_errno("cannot list the host root directory");
	while ((de = readdir(dir))) {
		const char *name = de->d_name;

		if (!strcmp(name, ".") || !strcmp(name, "..") ||
		    !strcmp(name, "nix") || !strcmp(name, "proc"))
			continue;

		/* lstat, not stat: we want to see symlinks as symlinks. */
		if (fstatat(dirfd(dir), name, &st, AT_SYMLINK_NOFOLLOW) < 0)
			continue;
		snprintf(src, sizeof(src), "/oldroot/%s", name);
		snprintf(dst, sizeof(dst), "/newroot/%s", name);

		if (S_ISLNK(st.st_mode)) {
			/*
			 * Top-level symlink, e.g. on merged-/usr distros
			 * /bin -> usr/bin and /lib64 -> usr/lib64. Recreate it
			 * with the same target text so paths resolve exactly as
			 * on the host.
			 */
			n = readlink(src, target, sizeof(target) - 1);
			if (n < 0)
				continue;
			target[n] = '\0';
			if (symlink(target, dst) < 0)
				warn_errno("cannot recreate /%s", name);
		} else if (S_ISDIR(st.st_mode)) {
			/*
			 * Real directory: create an empty mount point and
			 * bind-mount the host directory onto it.
			 *
			 * MS_REC makes the bind recursive, so mounts inside it
			 * come along too: /dev/pts and /dev/shm under /dev,
			 * /run/user/<uid> under /run, a separate /home
			 * partition, /sys/fs/cgroup, and so on.
			 *
			 * Unlike bwrap's plain --bind, we do not add "nodev",
			 * so /dev keeps working as a device directory (we need
			 * /dev/fuse, and programs want /dev/null, /dev/tty,
			 * /dev/urandom, ...). It still grants nothing new:
			 * device permissions are exactly the host's.
			 */
			if (mkdir(dst, 0755) < 0 ||
			    mount(src, dst, NULL, MS_BIND | MS_REC, NULL) < 0)
				warn_errno("cannot bind-mount /%s", name);
		}
		/*
		 * Anything else at the top level (e.g. a /swap.img file) is not
		 * needed by programs and is skipped.
		 */
	}
	closedir(dir);

	/*
	 * A fresh /proc for our PID namespace, so that /proc/self, /proc/<pid>
	 * and tools like `ps` describe the sandbox rather than the host. The
	 * kernel only lets a user namespace mount procfs if an unobstructed
	 * procfs is already visible to it. The host /proc at /oldroot/proc
	 * satisfies that, which is why this happens before /oldroot goes away.
	 *
	 * MS_NOSUID | MS_NODEV | MS_NOEXEC are the usual flags for /proc.
	 */
	if (mkdir("/newroot/proc", 0555) < 0 ||
	    mount("proc", "/newroot/proc", "proc",
		  MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0)
		die_errno("cannot mount /proc");

	/* The empty mount point for the closure (and /nix above it). */
	if (mkdir("/newroot/nix", 0755) < 0 ||
	    mkdir("/newroot/nix/store", 0755) < 0)
		die_errno("cannot create /nix/store");

	/*
	 * Second pivot: make /newroot the root, and get rid of the base tmpfs
	 * and the host root hanging off it.
	 *
	 * pivot_root(".", ".") is a documented trick (see pivot_root(2)): with
	 * the new root as the current directory, it stacks the old root on top
	 * of the new one at "/". umount2(".", MNT_DETACH) then unmounts that top
	 * layer, which leaves only the new root. MNT_DETACH ("lazy unmount")
	 * means: do it even though things below are still in use.
	 *
	 * Our bind mounts inside /newroot are separate mounts, so they stay.
	 */
	if (chdir("/newroot") < 0)
		die_errno("cannot chdir to the new root");
	if (pivot_root(".", ".") < 0)
		die_errno("cannot pivot into the new root");
	if (umount2(".", MNT_DETACH) < 0)
		die_errno("cannot detach the old root");
	if (chdir("/") < 0)
		die_errno("cannot chdir to /");

	/*
	 * Finally make the tmpfs root read-only, so the program cannot
	 * accidentally create files at the top level that would silently
	 * disappear when it exits. This only affects the tmpfs itself; the
	 * bind-mounted host directories keep their own flags and stay as
	 * writable as they are on the host.
	 *
	 * MS_REMOUNT | MS_BIND changes the flags of this one mount without
	 * touching the filesystem underneath. Mounting FUSE onto /nix/store
	 * still works afterwards: a read-only filesystem can have mount points.
	 */
	if (mount(NULL, "/", NULL,
		  MS_REMOUNT | MS_BIND | MS_RDONLY | MS_NOSUID | MS_NODEV,
		  NULL) < 0)
		warn_errno("cannot make the root read-only");
}

/* -----------------------------------------------------------------------------
 * Step 4 (FUSE): serve the EROFS image at /nix/store
 * -------------------------------------------------------------------------- */

/*
 * Write end of the "mount is ready" pipe, used by __wrap_fuse_daemonize().
 * Only meaningful in the FUSE process.
 */
static int fuse_ready_fd = -1;

/*
 * Replacement for libfuse's fuse_daemonize().
 *
 * The launcher is linked with `-Wl,--wrap=fuse_daemonize`. That tells the
 * linker: every call to fuse_daemonize() in any object file (including the
 * ones inside liberofsfuse.a) should call __wrap_fuse_daemonize() instead.
 *
 * erofsfuse_main() calls fuse_daemonize() exactly once, right after the FUSE
 * mount has succeeded and just before it starts serving requests. That makes
 * it the perfect "the mount is ready" hook, without patching erofs-utils:
 *
 *   1. Silence the FUSE process. erofsfuse prints a version banner and an
 *      "image mounted" notice on every start. Until now its stdout and stderr
 *      went into a pipe that INIT only shows if mounting fails. From here on
 *      they go to /dev/null, so nothing it prints can appear in the middle of
 *      the program's output.
 *   2. Tell INIT that /nix/store is ready, by writing one byte to the pipe.
 *   3. Return 0 ("success") WITHOUT actually daemonizing. The real
 *      fuse_daemonize() would fork into the background and detach from the
 *      terminal; we want this process to stay exactly where it is, a child of
 *      INIT, so it dies together with the PID namespace.
 */
int __wrap_fuse_daemonize(int foreground)
{
	int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);

	(void)foreground;
	if (null_fd >= 0) {
		dup2(null_fd, STDOUT_FILENO);
		dup2(null_fd, STDERR_FILENO);
		close(null_fd);
	}
	if (write(fuse_ready_fd, "R", 1) != 1)
		return -1;
	close(fuse_ready_fd);
	return 0;
}

/*
 * Body of the FUSE process. Never returns.
 *
 *   self_fd   open file descriptor of the bundle file
 *   ready_fd  write end of the "mount is ready" pipe
 *   log_fd    write end of the pipe that collects erofsfuse's output
 *   oldmask   signal mask to restore (see run_init)
 */
static void run_fuse(const struct bundle *b, int self_fd, int ready_fd,
		     int log_fd, const sigset_t *oldmask)
{
	char offset_arg[64], image_arg[64];
	int null_fd;

	/*
	 * Move into a process group of our own. Keyboard signals (Ctrl-C,
	 * Ctrl-\) go to the terminal's foreground process group, which is the
	 * group OUTER, INIT and PROGRAM are in. If the FUSE server got Ctrl-C,
	 * libfuse would shut it down and unmount /nix/store, while the program
	 * might still be handling that same Ctrl-C and need its files (Python,
	 * for example, loads modules to print the KeyboardInterrupt traceback).
	 */
	setpgid(0, 0);

	/* Undo the "block all signals" from run_init() for this process. */
	sigprocmask(SIG_SETMASK, oldmask, NULL);

	/*
	 * stdin: /dev/null; the server never reads the terminal.
	 * stdout, stderr: the log pipe (see __wrap_fuse_daemonize).
	 */
	null_fd = open("/dev/null", O_RDONLY);
	if (null_fd >= 0) {
		dup2(null_fd, STDIN_FILENO);
		close(null_fd);
	}
	dup2(log_fd, STDOUT_FILENO);
	dup2(log_fd, STDERR_FILENO);
	close(log_fd);

	fuse_ready_fd = ready_fd;

	/*
	 * The erofsfuse command line:
	 *
	 *   -f                  stay in the foreground. Our fuse_daemonize()
	 *                       replacement never forks anyway, but this states
	 *                       the intent.
	 *   --offset=N          the image starts N bytes into the file, right
	 *                       after this launcher; erofsfuse reads it in place.
	 *   /proc/self/fd/N     the image file. We pass the already-open bundle
	 *                       file instead of its path, because the path may be
	 *                       under /nix/store (e.g. ./result/bin/jq), which is
	 *                       exactly what is about to be covered up. Opening
	 *                       /proc/self/fd/N reopens the same file no matter
	 *                       where it lives.
	 *   /nix/store          the mount point created by setup_root().
	 *
	 * How the mount works without root or fusermount: we hold CAP_SYS_ADMIN
	 * in our user namespace, and the kernel allows FUSE to be mounted from a
	 * user namespace. libfuse therefore calls mount(2) itself instead of
	 * needing the setuid `fusermount3` helper.
	 */
	snprintf(offset_arg, sizeof(offset_arg), "--offset=%llu",
		 (unsigned long long)b->image_offset);
	snprintf(image_arg, sizeof(image_arg), "/proc/self/fd/%d", self_fd);

	char *argv[] = { "erofsfuse", "-f", offset_arg, image_arg,
			 "/nix/store", NULL };

	/*
	 * Only returns once the server stops (or failed to start). If it
	 * failed before mounting, the ready pipe was never written and INIT
	 * sees end-of-file on it when this process exits.
	 */
	_exit(erofsfuse_main(5, argv));
}

/* -----------------------------------------------------------------------------
 * Step 5 (PROGRAM): become the real program
 * -------------------------------------------------------------------------- */

/* Never returns. */
static void run_program(const struct bundle *b, const char *cwd, int argc,
			char **argv, const sigset_t *oldmask)
{
	char **pargv;
	int i;

	/*
	 * Go back to the directory the bundle was started from, so relative
	 * paths in the arguments work. The pivots reset our working directory
	 * to "/". If the old directory is not visible in the sandbox (it was
	 * under /nix, say), fall back to "/".
	 */
	if (chdir(cwd) < 0 && chdir("/") < 0)
		die_errno("cannot chdir to /");

	/*
	 * Signal handlers and mask: give the program the same setup the bundle
	 * was started with. Put the forwarded signals back to their defaults
	 * FIRST, then restore the original mask, so a signal that was waiting
	 * cannot run our handler in this process. (execve() would reset
	 * handlers anyway; the order just closes the gap before it.)
	 */
	reset_forwarders();
	sigprocmask(SIG_SETMASK, oldmask, NULL);

	/*
	 * no_new_privs: execve() may never grant more privileges than we
	 * have, so setuid/setgid binaries and file capabilities do not take
	 * effect. bwrap sets this too. It mainly makes behaviour predictable,
	 * since setuid to a user outside our namespace could not work anyway.
	 */
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
		die_errno("cannot set no_new_privs");

	/*
	 * Build argv for the program: argv[0] is its own path (what a shell
	 * would pass), followed by all of the bundle's arguments unchanged.
	 */
	pargv = calloc((size_t)argc + 1, sizeof(char *));
	if (!pargv)
		die("out of memory");
	pargv[0] = (char *)b->exec;
	for (i = 1; i < argc; i++)
		pargv[i] = argv[i];
	pargv[argc] = NULL;

	/*
	 * Capabilities: this process holds every capability in our user
	 * namespace. It does not need to drop them explicitly: our uid inside
	 * the namespace is not 0, and for such a process execve() clears all
	 * capabilities, so the program starts with none.
	 *
	 * File descriptors: the bundle file and the status pipe were opened
	 * with O_CLOEXEC, so the program does not inherit them. It gets only
	 * stdin, stdout, stderr and whatever else the caller passed in.
	 */
	execve(b->exec, pargv, environ);
	die_errno("cannot execute %s", b->exec);
}

/* -----------------------------------------------------------------------------
 * Step 2 (INIT): PID 1 of the sandbox. Never returns.
 * -------------------------------------------------------------------------- */

static void run_init(const struct bundle *b, int self_fd, int status_fd,
		     const char *cwd, int argc, char **argv,
		     const sigset_t *oldmask)
{
	int ready[2], log[2];
	pid_t fuse_pid, prog_pid, pid;
	char buf[4096], c;
	ssize_t n;
	int status;

	/*
	 * If OUTER dies (even from SIGKILL), have the kernel SIGKILL us. And
	 * because we are PID 1, that takes down the whole sandbox with us.
	 * Same idea as bwrap's --die-with-parent.
	 */
	prctl(PR_SET_PDEATHSIG, SIGKILL);

	setup_root();

	/*
	 * Two pipes to talk to the FUSE process:
	 *   ready  it writes one byte once /nix/store is mounted
	 *   log    its stdout/stderr until then, shown only if it fails
	 * O_CLOEXEC: PROGRAM must not inherit them.
	 */
	if (pipe2(ready, O_CLOEXEC) < 0 || pipe2(log, O_CLOEXEC) < 0)
		die_errno("cannot create pipes");

	fuse_pid = fork();
	if (fuse_pid < 0)
		die_errno("cannot fork the FUSE server");
	if (fuse_pid == 0) {
		close(ready[0]);
		close(log[0]);
		close(status_fd);
		run_fuse(b, self_fd, ready[1], log[1], oldmask);
	}

	/*
	 * Close OUR copies of the write ends. This matters: a pipe only
	 * reports end-of-file once every copy of its write end is closed. If
	 * we kept ours, the read() below would hang forever if the FUSE
	 * server died before mounting.
	 */
	close(ready[1]);
	close(log[1]);

	/*
	 * Wait for the mount. read() returns:
	 *   1   the ready byte: /nix/store is mounted
	 *   0   end-of-file: the FUSE process exited without mounting
	 */
	do
		n = read(ready[0], &c, 1);
	while (n < 0 && errno == EINTR);

	if (n != 1) {
		/* Show whatever erofsfuse printed, then give up. */
		while ((n = read(log[0], buf, sizeof(buf))) > 0)
			fwrite(buf, 1, (size_t)n, stderr);
		die("could not mount the closure at /nix/store");
	}
	close(ready[0]);
	close(log[0]);

	/*
	 * Start the program. Signals are still blocked (see main), so a
	 * forwarded signal cannot arrive before forward_to is set; it waits
	 * until the sigprocmask() below and is then passed on.
	 */
	install_forwarders();
	prog_pid = fork();
	if (prog_pid < 0)
		die_errno("cannot fork the program");
	if (prog_pid == 0)
		run_program(b, cwd, argc, argv, oldmask);
	forward_to = prog_pid;
	sigprocmask(SIG_SETMASK, oldmask, NULL);

	/*
	 * PID 1 duties. Any process in the namespace whose parent exits is
	 * re-parented to us, and someone has to wait() for it or it stays a
	 * zombie. So wait for ANY child (-1), and look at which one it was.
	 */
	for (;;) {
		pid = waitpid(-1, &status, 0);
		if (pid < 0) {
			if (errno == EINTR)
				continue;
			/* ECHILD: no children left, which cannot really happen
			 * while PROGRAM is running. Give up cleanly. */
			_exit(EXIT_LAUNCH_FAILED);
		}

		if (pid == prog_pid) {
			/*
			 * PROGRAM is done. Send its raw wait status (exit code
			 * or signal) to OUTER, then exit. Exiting as PID 1 makes
			 * the kernel kill everything else in the namespace,
			 * including the FUSE server and any background
			 * processes the program left behind.
			 */
			if (write(status_fd, &status, sizeof(status)) < 0)
				_exit(EXIT_LAUNCH_FAILED);
			_exit(0);
		}

		if (pid == fuse_pid)
			/* Accesses to /nix/store will now fail with "Transport
			 * endpoint is not connected". Say why. */
			fputs("self-hoisted-nix: warning: the FUSE server for "
			      "/nix/store exited unexpectedly\n", stderr);

		/* Anything else was an orphan we just reaped. Keep waiting. */
	}
}

/* -----------------------------------------------------------------------------
 * main (OUTER)
 * -------------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	char cwd[PATH_MAX], map[64];
	sigset_t all, oldmask;
	struct bundle b;
	int self_fd, status_pipe[2], status;
	uid_t uid = getuid();
	gid_t gid = getgid();
	pid_t init_pid;
	struct rlimit no_core = { 0, 0 };
	ssize_t n;

	/*
	 * Open our own file. /proc/self/exe is a link to the executable of
	 * the running process, i.e. the bundle. It works no matter how we
	 * were started ($PATH, relative path, symlink), and keeps pointing at
	 * the right file even after the mounts below cover up its path.
	 * O_CLOEXEC: the program must not inherit it.
	 */
	self_fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
	if (self_fd < 0)
		die_errno("cannot open /proc/self/exe");
	read_trailer(self_fd, &b);

	/* Remember where we were started from, for run_program(). */
	if (!getcwd(cwd, sizeof(cwd)))
		strcpy(cwd, "/");

	/*
	 * Create the namespaces. All three in one call; the new user namespace
	 * is created first and owns the other two, which is what lets an
	 * ordinary user create them.
	 *
	 *   CLONE_NEWUSER  A new user namespace. We get every capability inside
	 *                  it (none outside), which is what allows the mounts.
	 *   CLONE_NEWNS    A new mount namespace: a private copy of the mount
	 *                  table, so our mounts never affect the host.
	 *   CLONE_NEWPID   A new PID namespace. Unlike the other two, this one
	 *                  does not apply to us but to our NEXT child, which
	 *                  becomes its PID 1 (INIT).
	 *
	 * This fails if unprivileged user namespaces are disabled, e.g. by
	 * Ubuntu 24.04+'s AppArmor restriction or inside many containers.
	 */
	if (unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID) < 0)
		die_errno("cannot create a user namespace (are unprivileged "
			  "user namespaces disabled on this host?)");

	/*
	 * Map our own uid and gid into the new user namespace, so inside it we
	 * are the same user as outside (files we own still look like ours).
	 * An ordinary user may map exactly one id: their own. The format is
	 * "<id inside> <id outside> <count>".
	 *
	 * setgroups must be set to "deny" before an ordinary user may write
	 * gid_map. That forbids setgroups() in the sandbox, so the process
	 * cannot drop supplementary groups and gain access that a "deny"
	 * permission on one of them was blocking.
	 */
	write_file("/proc/self/setgroups", "deny");
	snprintf(map, sizeof(map), "%u %u 1\n", (unsigned)uid, (unsigned)uid);
	write_file("/proc/self/uid_map", map);
	snprintf(map, sizeof(map), "%u %u 1\n", (unsigned)gid, (unsigned)gid);
	write_file("/proc/self/gid_map", map);

	/*
	 * INIT sends PROGRAM's wait status back through this pipe.
	 *
	 * Why not just use INIT's own exit status? An exit status cannot say
	 * "was killed by SIGSEGV": INIT can only exit(), not re-die of the
	 * same signal (PID 1 is protected from most signals). The raw wait
	 * status carries both cases, and we can then reproduce either one.
	 */
	if (pipe2(status_pipe, O_CLOEXEC) < 0)
		die_errno("cannot create a pipe");

	/*
	 * Block all signals across the fork, so none can arrive in the window
	 * before our handlers and forward_to are set up. Blocked signals are
	 * not lost; they are delivered once we unblock.
	 */
	sigfillset(&all);
	sigprocmask(SIG_BLOCK, &all, &oldmask);

	init_pid = fork();
	if (init_pid < 0)
		die_errno("cannot fork");
	if (init_pid == 0) {
		close(status_pipe[0]);
		run_init(&b, self_fd, status_pipe[1], cwd, argc, argv,
			 &oldmask);
	}
	close(status_pipe[1]);
	close(self_fd);

	/* From here on OUTER only forwards signals and waits. */
	install_forwarders();
	forward_to = init_pid;
	sigprocmask(SIG_SETMASK, &oldmask, NULL);

	while (waitpid(init_pid, &status, 0) < 0)
		if (errno != EINTR)
			die_errno("waitpid");

	/* Did INIT report PROGRAM's status? */
	do
		n = read(status_pipe[0], &status, sizeof(status));
	while (n < 0 && errno == EINTR);

	if (n != sizeof(status)) {
		/*
		 * No: INIT failed during setup (it has already printed why and
		 * exited with EXIT_LAUNCH_FAILED), or was killed. Pass on its
		 * exit code if it has one.
		 */
		return WIFEXITED(status) ? WEXITSTATUS(status)
					 : EXIT_LAUNCH_FAILED;
	}

	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	/*
	 * PROGRAM was killed by a signal. Die of the same signal, so that the
	 * shell and other callers see exactly that (e.g. bash stops a script
	 * loop when a child dies of SIGINT, and prints "Segmentation fault"
	 * for SIGSEGV).
	 *
	 * Disable core dumps first: if PROGRAM dumped core, we do not want a
	 * second, useless core file of the launcher. Then restore the default
	 * action (our forwarder is still installed), unblock the signal and
	 * raise it.
	 */
	setrlimit(RLIMIT_CORE, &no_core);
	signal(WTERMSIG(status), SIG_DFL);
	sigemptyset(&all);
	sigaddset(&all, WTERMSIG(status));
	sigprocmask(SIG_UNBLOCK, &all, NULL);
	raise(WTERMSIG(status));

	/* Only reached for signals whose default action is not to terminate. */
	return 128 + WTERMSIG(status);
}
