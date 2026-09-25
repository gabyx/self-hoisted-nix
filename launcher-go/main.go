// =============================================================================
// self-hoisted-nix launcher, Go version
// =============================================================================
//
// A drop-in alternative to ../launcher.c, written in pure Go (no cgo). It
// reads the same bundle format:
//
//	[ this launcher, padded to 4 KiB ][ EROFS image ][ 4 KiB text trailer ]
//
// and runs the program the same way: new user, mount and PID namespaces, a
// rebuilt root without the host's /nix, the EROFS image served over FUSE at
// /nix/store, and the program exec'd inside.
//
// The pieces:
//
//   - FUSE server: github.com/hanwen/go-fuse/v2, a pure-Go FUSE library.
//   - EROFS reader: github.com/Xe/erofs, a pure-Go EROFS reader.
//
// LIMITATION, found by testing: no pure-Go EROFS reader available today can
// read the compressed images that mkfs.erofs 1.9 writes. erofs/go-erofs
// v0.3.1 and forkcloser/erofs v1.0.0 reject compressed images outright, and
// Xe/erofs v0.8.0 fails on every compressed file ("reading compact pcluster:
// EOF"). All three read uncompressed images correctly. So bundles for this
// launcher must be built with an UNCOMPRESSED image (mkErofsBundle's
// `mkfsFlags = [ ]`), which makes them considerably bigger.
//
// Processes, and why there are more than in the C version
// ------------------------------------------------------
//
// C can fork() and keep running the same code in the child. Go cannot: the Go
// runtime is multithreaded, and a forked child would contain only the one
// thread that called fork(), with the runtime's locks in whatever state the
// other threads left them. So Go only offers fork+exec (os.StartProcess).
// Every "process role" below is therefore started by re-exec'ing this same
// file (/proc/self/exe) with the role in an environment variable:
//
//	OUTER  the process you started. Reads the trailer, starts INIT in new
//	       user+mount+PID namespaces, forwards signals, and exits the way
//	       the program did.
//	INIT   PID 1 of the new PID namespace. Builds the new root, mounts FUSE
//	       on /nix/store with plain system calls, starts FUSE and EXEC, and
//	       reaps processes.
//	FUSE   Locks itself out of exec() with seccomp, then serves the EROFS
//	       image on the already-mounted /dev/fuse descriptor.
//	EXEC   A short-lived helper that drops the capabilities INIT needed, then
//	       exec()s the real program (see exec.go for why this has to be a
//	       separate step in Go).
//
// Everything is started from this one file, so nothing here ever runs a
// program from the host, just as with the C version.
//
// Exit status: the bundle exits with the program's exit status, or dies of
// the same signal. If the launcher itself fails it prints a
// "self-hoisted-nix:" message and exits with 127.
// =============================================================================
package main

import (
	"encoding/binary"
	"io"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"golang.org/x/sys/unix"
)

// Environment variables used to hand information to re-exec'd roles. Each
// role removes them from its environment first thing, so the program never
// sees them.
const (
	roleEnv = "SELF_HOISTED_NIX_ROLE"
	cwdEnv  = "SELF_HOISTED_NIX_CWD"
)

func main() {
	role := os.Getenv(roleEnv)
	os.Unsetenv(roleEnv)

	switch role {
	case "":
		runOuter()
	case "init":
		runInit()
	case "fuse":
		runFuse()
	case "exec":
		runExec()
	default:
		fail("unknown role %q", role)
	}
}

// -----------------------------------------------------------------------------
// OUTER
// -----------------------------------------------------------------------------

func runOuter() {
	// Validate the bundle up front, so a broken file fails with a clear
	// message before any namespaces exist. Every role reads the trailer
	// again itself; it is only 4 KiB, and passing it along would be more
	// code than re-reading it.
	self, err := os.Open("/proc/self/exe")
	if err != nil {
		fail("cannot open /proc/self/exe: %v", err)
	}
	if _, err := readTrailer(self); err != nil {
		fail("%v", err)
	}
	self.Close()

	cwd, err := os.Getwd()
	if err != nil {
		cwd = "/"
	}

	// INIT sends the program's raw wait status back through this pipe, for
	// the same reason as in the C version: an exit code cannot say "was
	// killed by SIGSEGV", and PID 1 cannot re-die of a signal to show it.
	statusR, statusW, err := os.Pipe()
	if err != nil {
		fail("cannot create a pipe: %v", err)
	}

	// Pdeathsig ("kill the child when its parent dies") is tied to the
	// THREAD that created the child, not the process. The Go scheduler can
	// retire idle threads, which would fire the signal while we are still
	// alive. Pinning this goroutine to its thread for the rest of the
	// program keeps that thread alive.
	runtime.LockOSThread()

	uid, gid := os.Getuid(), os.Getgid()
	proc, err := os.StartProcess("/proc/self/exe",
		append([]string{"self-hoisted-nix (init)"}, os.Args[1:]...),
		&os.ProcAttr{
			Env:   append(os.Environ(), roleEnv+"=init", cwdEnv+"="+cwd),
			Files: []*os.File{os.Stdin, os.Stdout, os.Stderr, statusW},
			Sys: &syscall.SysProcAttr{
				// Same three namespaces as launcher.c. Go's
				// runtime does the clone() and writes the uid/gid
				// maps for us from the parent side.
				Cloneflags: syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS |
					syscall.CLONE_NEWPID,
				UidMappings: []syscall.SysProcIDMap{{ContainerID: uid, HostID: uid, Size: 1}},
				GidMappings: []syscall.SysProcIDMap{{ContainerID: gid, HostID: gid, Size: 1}},
				// Writes "deny" to /proc/<pid>/setgroups, which an
				// ordinary user must do before writing gid_map.
				GidMappingsEnableSetgroups: false,
				// The child gets every capability in its new user
				// namespace, but then it exec()s, and for a non-root
				// uid execve() clears all capabilities. (In C, INIT
				// is a fork() and never execs, so it keeps them.)
				// Ambient capabilities are the one kind that survive
				// execve(), so Go raises CAP_SYS_ADMIN as ambient in
				// the child before its exec. INIT needs it for the
				// mounts.
				AmbientCaps: []uintptr{unix.CAP_SYS_ADMIN},
				Pdeathsig:   syscall.SIGKILL,
			},
		})
	if err != nil {
		fail("cannot create a user namespace (are unprivileged user "+
			"namespaces disabled on this host?): %v", err)
	}
	statusW.Close()

	forwardSignals(func() int { return proc.Pid })

	state, err := proc.Wait()
	if err != nil {
		fail("waiting for the sandbox: %v", err)
	}

	var buf [4]byte
	if _, err := io.ReadFull(statusR, buf[:]); err != nil {
		// INIT failed during setup (it printed why) or was killed.
		if state.Exited() {
			os.Exit(state.ExitCode())
		}
		os.Exit(exitLaunchFailed)
	}
	ws := syscall.WaitStatus(binary.NativeEndian.Uint32(buf[:]))
	if ws.Signaled() {
		dieOfSignal(ws.Signal())
	}
	os.Exit(ws.ExitStatus())
}

// forwardSignals passes deliberately-sent signals on to target().
//
// DIFFERENCE FROM THE C VERSION: the C launcher tells Ctrl-C (sent by the
// kernel to the whole foreground process group, so the program already gets
// it) apart from `kill -INT <pid>` (sent to us only), using siginfo's si_code.
// Go's os/signal delivers only the signal number, not the siginfo. So we
// cannot tell the two apart, and choose:
//
//   - SIGINT, SIGQUIT: never forwarded. Ctrl-C and Ctrl-\ reach the program
//     directly and are not duplicated, but `kill -INT <bundle pid>` does not
//     reach the program.
//   - SIGTERM, SIGHUP, SIGUSR1, SIGUSR2: always forwarded. `kill` works,
//     but a terminal hangup (a kernel SIGHUP to the whole group) reaches the
//     program twice.
//
// Receiving SIGINT/SIGQUIT through signal.Notify, rather than ignoring them
// with signal.Ignore, matters: an ignored signal stays ignored across exec(),
// so the program would start with Ctrl-C disabled. A caught one is reset to
// the default action by exec().
//
// Catching them also matters for INIT: a Go program's default reaction to
// SIGINT is to exit, and INIT exiting would tear down the sandbox.
func forwardSignals(target func() int) {
	ch := make(chan os.Signal, 16)
	signal.Notify(ch, syscall.SIGHUP, syscall.SIGINT, syscall.SIGQUIT,
		syscall.SIGTERM, syscall.SIGUSR1, syscall.SIGUSR2)
	go func() {
		for s := range ch {
			sig := s.(syscall.Signal)
			if sig == syscall.SIGINT || sig == syscall.SIGQUIT {
				continue
			}
			if pid := target(); pid > 0 {
				syscall.Kill(pid, sig)
			}
		}
	}()
}

// dieOfSignal makes this process die of `sig`, so callers see exactly what
// the program did (bash prints "Segmentation fault", stops loops on SIGINT).
//
// DIFFERENCE FROM THE C VERSION, where this is signal(sig, SIG_DFL) plus
// raise(sig): the Go runtime installs its own handlers for signals like
// SIGSEGV and SIGBUS, and on receiving one it prints a goroutine dump and
// exits with status 2 instead of dying of the signal. os/signal cannot
// uninstall the runtime's own handlers. So we go around the runtime: set the
// default action with the raw rt_sigaction system call, unblock the signal on
// this thread, and send it to this thread with tgkill.
func dieOfSignal(sig syscall.Signal) {
	// No second, useless core file of the launcher.
	unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{})

	// Layout of the kernel's struct sigaction on amd64 and arm64. All zero
	// is SIG_DFL, no flags, empty mask.
	var act struct {
		handler  uintptr
		flags    uint64
		restorer uintptr
		mask     uint64
	}
	runtime.LockOSThread()
	unix.RawSyscall6(unix.SYS_RT_SIGACTION, uintptr(sig),
		uintptrOf(&act), 0, 8, 0, 0)

	var set unix.Sigset_t
	set.Val[(sig-1)/64] |= 1 << ((uint(sig) - 1) % 64)
	unix.PthreadSigmask(unix.SIG_UNBLOCK, &set, nil)

	unix.Tgkill(os.Getpid(), unix.Gettid(), sig)

	// Only reached for signals whose default action is not to terminate.
	os.Exit(128 + int(sig))
}
