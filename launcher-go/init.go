package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

// runInit is PID 1 of the sandbox. File descriptor 3 is the status pipe to
// OUTER. It holds CAP_SYS_ADMIN in our user namespace (as an ambient
// capability, see runOuter).
func runInit() {
	status := os.NewFile(3, "status")

	// Catch signals right away (see forwardSignals): a Go program exits on
	// SIGINT by default, and INIT exiting kills the sandbox. The target is
	// read when a signal arrives, so it starts forwarding once the program
	// exists.
	var progPid int
	forwardSignals(func() int { return progPid })

	setupRoot()
	fuseDev := mountFuse()

	// Start FUSE. Its file descriptors are set up by position:
	//   0 /dev/null, 1+2 the log pipe (shown only if it fails),
	//   3 the mounted /dev/fuse channel, 4 the bundle file,
	//   5 the "ready" pipe.
	self, err := os.Open("/proc/self/exe")
	if err != nil {
		fail("cannot open /proc/self/exe: %v", err)
	}
	readyR, readyW, err := os.Pipe()
	if err != nil {
		fail("cannot create a pipe: %v", err)
	}
	logR, logW, err := os.Pipe()
	if err != nil {
		fail("cannot create a pipe: %v", err)
	}
	devNull, err := os.Open(os.DevNull)
	if err != nil {
		fail("cannot open /dev/null: %v", err)
	}
	fuseProc, err := os.StartProcess("/proc/self/exe",
		[]string{"self-hoisted-nix (fuse)"},
		&os.ProcAttr{
			Env:   append(os.Environ(), roleEnv+"=fuse"),
			Files: []*os.File{devNull, logW, logW, fuseDev, self, readyW},
			Sys: &syscall.SysProcAttr{
				// Its own process group, so Ctrl-C (sent to the
				// terminal's foreground group) cannot stop the
				// server while the program still needs its files.
				Setpgid: true,
			},
		})
	if err != nil {
		fail("cannot start the FUSE server: %v", err)
	}

	// Close OUR copies. For the pipes: end-of-file only arrives once every
	// write end is closed. For /dev/fuse: if the server dies, the kernel
	// disconnects the mount only once no process holds the channel open,
	// so accesses fail instead of waiting forever.
	fuseDev.Close()
	readyW.Close()
	logW.Close()
	devNull.Close()
	self.Close()

	var ready [1]byte
	if n, _ := readyR.Read(ready[:]); n != 1 {
		io.Copy(os.Stderr, logR)
		fail("could not mount the closure at /nix/store")
	}
	readyR.Close()
	logR.Close()

	// Start the program, through the EXEC helper (see exec.go). It gets
	// the original arguments, environment and stdio. The working directory
	// is still in cwdEnv, which EXEC consumes.
	prog, err := os.StartProcess("/proc/self/exe",
		append([]string{"self-hoisted-nix (exec)"}, os.Args[1:]...),
		&os.ProcAttr{
			Env:   append(os.Environ(), roleEnv+"=exec"),
			Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
		})
	if err != nil {
		fail("cannot start the program: %v", err)
	}
	progPid = prog.Pid

	// PID 1 duties: reap every child, including orphans re-parented to us.
	// We call wait4(-1) ourselves rather than os.Process.Wait, which waits
	// for one specific child and leaves orphans as zombies.
	for {
		var ws syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &ws, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			os.Exit(exitLaunchFailed)
		}
		switch pid {
		case progPid:
			// Report the raw status to OUTER and exit. PID 1
			// exiting makes the kernel kill everything else in the
			// namespace, including the FUSE server.
			var buf [4]byte
			binary.NativeEndian.PutUint32(buf[:], uint32(ws))
			if _, err := status.Write(buf[:]); err != nil {
				os.Exit(exitLaunchFailed)
			}
			os.Exit(0)
		case fuseProc.Pid:
			warn("the FUSE server for /nix/store exited unexpectedly")
		}
	}
}

// setupRoot makes "/" a copy of the host's root, except that /nix/store is an
// empty directory and /proc belongs to our PID namespace. This is a direct
// port of setup_root() in launcher.c; see there for the reasoning behind
// each step (two pivots, why /tmp, why /proc must be mounted before the old
// root is detached, and so on).
func setupRoot() {
	must := func(err error, what string) {
		if err != nil {
			fail("%s: %v", what, err)
		}
	}

	// Keep our mounts from propagating to the host.
	must(unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""), "cannot make mounts private")

	// A build area: tmpfs "base" on /tmp, a tmpfs for the new root inside.
	must(unix.Mount("tmpfs", "/tmp", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755"),
		"cannot mount a tmpfs on /tmp")
	must(os.Mkdir("/tmp/newroot", 0o755), "cannot create /tmp/newroot")
	must(os.Mkdir("/tmp/oldroot", 0o755), "cannot create /tmp/oldroot")
	must(unix.Mount("tmpfs", "/tmp/newroot", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755"),
		"cannot mount the new root tmpfs")

	// First pivot: the base tmpfs becomes "/", the host root /oldroot.
	// Mounts and pivot_root act on the whole mount namespace, and the
	// working directory is shared by all threads of a process, so the Go
	// runtime's threads are no problem here.
	must(unix.PivotRoot("/tmp", "/tmp/oldroot"), "cannot pivot into the build area")
	must(os.Chdir("/"), "cannot chdir to /")

	// Recreate each top-level entry of the host root, except nix and proc.
	entries, err := os.ReadDir("/oldroot")
	must(err, "cannot list the host root directory")
	for _, e := range entries {
		name := e.Name()
		if name == "nix" || name == "proc" {
			continue
		}
		src, dst := filepath.Join("/oldroot", name), filepath.Join("/newroot", name)
		switch {
		case e.Type()&os.ModeSymlink != 0:
			// e.g. /bin -> usr/bin: same symlink, same target text.
			target, err := os.Readlink(src)
			if err != nil {
				continue
			}
			if err := os.Symlink(target, dst); err != nil {
				warn("cannot recreate /%s: %v", name, err)
			}
		case e.IsDir():
			// Recursive bind, without adding nodev (so /dev works).
			if err := os.Mkdir(dst, 0o755); err != nil {
				warn("cannot bind-mount /%s: %v", name, err)
				continue
			}
			if err := unix.Mount(src, dst, "", unix.MS_BIND|unix.MS_REC, ""); err != nil {
				warn("cannot bind-mount /%s: %v", name, err)
			}
		}
	}

	// Fresh /proc for our PID namespace, while the host /proc is still
	// visible at /oldroot/proc (the kernel requires that).
	must(os.Mkdir("/newroot/proc", 0o555), "cannot create /proc")
	must(unix.Mount("proc", "/newroot/proc", "proc", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, ""),
		"cannot mount /proc")

	must(os.MkdirAll("/newroot/nix/store", 0o755), "cannot create /nix/store")

	// Second pivot, with the pivot_root(".", ".") trick, then detach the
	// old root.
	must(os.Chdir("/newroot"), "cannot chdir to the new root")
	must(unix.PivotRoot(".", "."), "cannot pivot into the new root")
	must(unix.Unmount(".", unix.MNT_DETACH), "cannot detach the old root")
	must(os.Chdir("/"), "cannot chdir to /")

	// Read-only tmpfs root.
	if err := unix.Mount("", "/", "", unix.MS_REMOUNT|unix.MS_BIND|unix.MS_RDONLY|
		unix.MS_NOSUID|unix.MS_NODEV, ""); err != nil {
		warn("cannot make the root read-only: %v", err)
	}
}

// mountFuse mounts an (empty, not yet served) FUSE filesystem on /nix/store
// with plain system calls, and returns the /dev/fuse channel. Same mount,
// same options, same reasoning as mount_fuse() in launcher.c: go-fuse, like
// libfuse, would otherwise run the setuid `fusermount` helper. Given the
// channel as the magic mountpoint "/dev/fd/N", go-fuse mounts nothing itself.
func mountFuse() *os.File {
	fd, err := unix.Open("/dev/fuse", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		fail("cannot open /dev/fuse: %v", err)
	}
	opts := fmt.Sprintf("fd=%d,rootmode=40000,user_id=%d,group_id=%d",
		fd, os.Getuid(), os.Getgid())
	if err := unix.Mount("self-hoisted-nix", "/nix/store", "fuse.erofs-go",
		unix.MS_RDONLY|unix.MS_NOSUID|unix.MS_NODEV, opts); err != nil {
		fail("cannot mount FUSE on /nix/store: %v", err)
	}
	return os.NewFile(uintptr(fd), "/dev/fuse")
}
