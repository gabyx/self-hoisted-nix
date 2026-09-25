package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unsafe"
)

// Exit status for "the launcher could not start the program".
const exitLaunchFailed = 127

// fail prints "self-hoisted-nix: <message>" and exits with exitLaunchFailed.
func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "self-hoisted-nix: "+format+"\n", args...)
	os.Exit(exitLaunchFailed)
}

// warn prints "self-hoisted-nix: warning: <message>" and carries on.
func warn(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "self-hoisted-nix: warning: "+format+"\n", args...)
}

// uintptrOf returns the address of v for passing to a raw system call.
func uintptrOf[T any](v *T) uintptr { return uintptr(unsafe.Pointer(v)) }

// -----------------------------------------------------------------------------
// The bundle trailer (same format as launcher.c's read_trailer)
// -----------------------------------------------------------------------------

const (
	trailerSize  = 4096
	trailerMagic = "self-hoisted-nix v1\n"
)

type bundle struct {
	imageOffset int64  // where the EROFS image starts, in bytes
	imageSize   int64  // how long it is, in bytes
	exec        string // program to run, a /nix/store/... path
}

// readTrailer parses the text trailer in the last 4 KiB of the bundle:
//
//	self-hoisted-nix v1
//	image-offset <bytes>
//	image-size <bytes>
//	exec <path>
//
// padded with NUL bytes. Unknown keys are ignored so later versions can add
// some.
func readTrailer(f *os.File) (*bundle, error) {
	st, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("cannot stat the bundle: %w", err)
	}
	if st.Size() < trailerSize {
		return nil, fmt.Errorf("this launcher has no bundle attached (file too small)")
	}

	buf := make([]byte, trailerSize)
	if _, err := f.ReadAt(buf, st.Size()-trailerSize); err != nil {
		return nil, fmt.Errorf("cannot read the bundle: %w", err)
	}
	text := string(bytes.TrimRight(buf, "\x00"))
	if !strings.HasPrefix(text, trailerMagic) {
		return nil, fmt.Errorf("this launcher has no bundle attached (no trailer found)")
	}

	b := &bundle{}
	for _, line := range strings.Split(text[len(trailerMagic):], "\n") {
		key, value, _ := strings.Cut(line, " ")
		switch key {
		case "image-offset":
			b.imageOffset, _ = strconv.ParseInt(value, 10, 64)
		case "image-size":
			b.imageSize, _ = strconv.ParseInt(value, 10, 64)
		case "exec":
			b.exec = value
		}
	}

	// Same sanity checks as the C version: a clear message instead of a
	// confusing FUSE error on a damaged file.
	if !strings.HasPrefix(b.exec, "/") {
		return nil, fmt.Errorf("bundle trailer has no valid \"exec\" line")
	}
	if b.imageOffset <= 0 || b.imageSize <= 0 ||
		b.imageOffset+b.imageSize > st.Size()-trailerSize {
		return nil, fmt.Errorf("bundle trailer has an invalid image offset or size")
	}
	return b, nil
}
