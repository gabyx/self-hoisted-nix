package main

import (
	"os"
	"runtime"

	"golang.org/x/sys/unix"
)

// runExec is the EXEC helper: the last step before the real program.
//
// Why this is a separate process in Go: INIT holds CAP_SYS_ADMIN as an
// AMBIENT capability, and ambient capabilities are exactly the ones that
// survive execve(). If INIT started the program directly, the program would
// inherit CAP_SYS_ADMIN. In C, run_program() runs in a forked child and simply
// exec()s: the uid is not 0, so execve() clears every capability.
//
// Clearing the ambient set has to happen in the process that calls execve(),
// and on the very THREAD that calls it: Linux keeps capabilities per thread.
// Go gives us no hook between fork and exec in os.StartProcess, and a Go
// process has several threads. Hence a helper that pins itself to one thread,
// clears the set there, and execs from that same thread.
func runExec() {
	runtime.LockOSThread()

	cwd := os.Getenv(cwdEnv)
	os.Unsetenv(cwdEnv)

	self, err := os.Open("/proc/self/exe")
	if err != nil {
		fail("cannot open /proc/self/exe: %v", err)
	}
	b, err := readTrailer(self)
	if err != nil {
		fail("%v", err)
	}
	self.Close()

	// The directory the bundle was started from, or "/" if it is not
	// visible in the sandbox.
	if os.Chdir(cwd) != nil {
		if err := os.Chdir("/"); err != nil {
			fail("cannot chdir to /: %v", err)
		}
	}

	// Drop the ambient capabilities on this thread. Our uid is not 0, so
	// with an empty ambient set execve() leaves the program with no
	// capabilities at all.
	if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0); err != nil {
		fail("cannot clear ambient capabilities: %v", err)
	}
	// no_new_privs, as in launcher.c (and bwrap): setuid binaries and file
	// capabilities do not take effect. Also a per-thread setting.
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		fail("cannot set no_new_privs: %v", err)
	}

	// argv[0] is the program's own path, then the bundle's arguments. The
	// environment is the caller's, with our variables already removed.
	// Signal handlers installed by the Go runtime are reset by execve().
	argv := append([]string{b.exec}, os.Args[1:]...)
	err = unix.Exec(b.exec, argv, os.Environ())
	fail("cannot execute %s: %v", b.exec, err)
}
