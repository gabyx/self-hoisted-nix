package main

import (
	"context"
	"io"
	"io/fs"
	"os"
	"path"
	"runtime"
	"syscall"
	"time"
	"unsafe"

	"github.com/Xe/erofs"
	gofs "github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
	"golang.org/x/sys/unix"
)

// runFuse is the FUSE server. File descriptors: 3 the mounted /dev/fuse
// channel, 4 the bundle file, 5 the "ready" pipe. stdout and stderr go to a
// pipe that INIT shows only if we fail before becoming ready.
func runFuse() {
	// Before anything else: from here on this process can never run
	// another program.
	forbidExec()

	self := os.NewFile(4, "bundle")
	ready := os.NewFile(5, "ready")

	b, err := readTrailer(self)
	if err != nil {
		fail("%v", err)
	}

	// Read the image in place: a window onto the bundle file, starting at
	// image-offset. Nothing is copied.
	image, err := erofs.Open(io.NewSectionReader(self, b.imageOffset, b.imageSize))
	if err != nil {
		fail("cannot open the EROFS image: %v", err)
	}
	root, err := newRoot(image)
	if err != nil {
		fail("cannot read the EROFS image: %v", err)
	}

	// The image never changes, so the kernel may cache names, attributes
	// and "does not exist" answers for as long as it likes.
	forever := 365 * 24 * time.Hour
	opts := &gofs.Options{
		EntryTimeout:    &forever,
		AttrTimeout:     &forever,
		NegativeTimeout: &forever,
	}

	// "/dev/fd/3": the magic mountpoint meaning "already mounted, this is
	// the channel". go-fuse then skips its own mount code, the part that
	// would run the setuid `fusermount` helper.
	//
	// gofs.Mount returns once the kernel's first request (FUSE_INIT) has
	// been answered, i.e. once /nix/store is actually usable. That is the
	// same moment the C version detects by wrapping fuse_daemonize().
	server, err := gofs.Mount("/dev/fd/3", root, opts)
	if err != nil {
		fail("cannot serve /nix/store: %v", err)
	}

	// Ready. From now on nothing we print could be useful, and it must not
	// end up in the middle of the program's output.
	if devNull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0); err == nil {
		unix.Dup2(int(devNull.Fd()), 1)
		unix.Dup2(int(devNull.Fd()), 2)
		devNull.Close()
	}
	if _, err := ready.Write([]byte("R")); err != nil {
		os.Exit(exitLaunchFailed)
	}
	ready.Close()

	// Serve until killed (when INIT, PID 1, exits).
	server.Wait()
	os.Exit(0)
}

// -----------------------------------------------------------------------------
// The filesystem
// -----------------------------------------------------------------------------

// node is any file, directory or symlink in the image, identified by its
// path. Nodes are created lazily: only when the kernel looks a name up (the
// first time a program touches it; after that the kernel's own caches answer,
// see the timeouts in runFuse). This is the same on-demand approach
// erofsfuse takes. An earlier version walked the whole image before mounting,
// which cost ~250 ms of startup for python3's ~9,500 entries.
type node struct {
	gofs.Inode
	image *erofs.FS
	path  string // "." for the root, as io/fs expects
	info  fs.FileInfo
}

var (
	_ gofs.NodeLookuper   = (*node)(nil)
	_ gofs.NodeReaddirer  = (*node)(nil)
	_ gofs.NodeGetattrer  = (*node)(nil)
	_ gofs.NodeReadlinker = (*node)(nil)
	_ gofs.NodeOpener     = (*node)(nil)
	_ gofs.NodeReader     = (*node)(nil)
)

func newRoot(image *erofs.FS) (*node, error) {
	info, err := image.Lstat(".")
	if err != nil {
		return nil, err
	}
	return &node{image: image, path: ".", info: info}, nil
}

// Lookup resolves one name in a directory.
func (n *node) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*gofs.Inode, syscall.Errno) {
	p := path.Join(n.path, name)
	info, err := n.image.Lstat(p)
	if err != nil {
		return nil, syscall.ENOENT
	}
	child := &node{image: n.image, path: p, info: info}
	child.fillAttr(&out.Attr)
	// Ino 0: go-fuse hands out inode numbers itself.
	return n.NewInode(ctx, child, gofs.StableAttr{Mode: fuseMode(info) & syscall.S_IFMT}), 0
}

// Readdir lists a directory.
func (n *node) Readdir(ctx context.Context) (gofs.DirStream, syscall.Errno) {
	entries, err := fs.ReadDir(n.image, n.path)
	if err != nil {
		return nil, syscall.EIO
	}
	list := make([]fuse.DirEntry, 0, len(entries))
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			return nil, syscall.EIO
		}
		list = append(list, fuse.DirEntry{Name: e.Name(), Mode: fuseMode(info) & syscall.S_IFMT})
	}
	return gofs.NewListDirStream(list), 0
}

func (n *node) Getattr(ctx context.Context, fh gofs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	n.fillAttr(&out.Attr)
	return 0
}

func (n *node) fillAttr(a *fuse.Attr) {
	a.Mode = fuseMode(n.info)
	if n.info.Mode().IsRegular() || n.info.Mode()&fs.ModeSymlink != 0 {
		a.Size = uint64(n.info.Size())
	}
	a.Blocks = (a.Size + 511) / 512
	if t := n.info.ModTime().Unix(); t > 0 {
		a.Mtime = uint64(t)
	}
}

func (n *node) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	target, err := n.image.ReadLink(n.path)
	if err != nil {
		return nil, syscall.EIO
	}
	return []byte(target), 0
}

// fileHandle is an open file. Xe/erofs implements io.ReaderAt for files in
// uncompressed images, which lets concurrent FUSE reads at different offsets
// go straight to the bundle without any locking or seeking.
type fileHandle struct {
	file fs.File
	at   io.ReaderAt
}

var _ gofs.FileReleaser = (*fileHandle)(nil)

func (h *fileHandle) Release(ctx context.Context) syscall.Errno {
	h.file.Close()
	return 0
}

func (n *node) Open(ctx context.Context, flags uint32) (gofs.FileHandle, uint32, syscall.Errno) {
	file, err := n.image.Open(n.path)
	if err != nil {
		return nil, 0, syscall.EIO
	}
	at, ok := file.(io.ReaderAt)
	if !ok {
		// A compressed file: see the note at the top of main.go.
		file.Close()
		return nil, 0, syscall.EIO
	}
	// FOPEN_KEEP_CACHE: the contents never change, so the kernel may keep
	// cached pages across opens instead of dropping them each time.
	return &fileHandle{file: file, at: at}, fuse.FOPEN_KEEP_CACHE, 0
}

func (n *node) Read(ctx context.Context, fh gofs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	got, err := fh.(*fileHandle).at.ReadAt(dest, off)
	if err != nil && err != io.EOF {
		return nil, syscall.EIO
	}
	return fuse.ReadResultData(dest[:got]), 0
}

// fuseMode converts Go's fs.FileMode into the Unix st_mode FUSE expects:
// file type bits plus permission bits, including setuid/setgid/sticky.
func fuseMode(info fs.FileInfo) uint32 {
	m := info.Mode()
	mode := uint32(m.Perm())
	if m&fs.ModeSetuid != 0 {
		mode |= syscall.S_ISUID
	}
	if m&fs.ModeSetgid != 0 {
		mode |= syscall.S_ISGID
	}
	if m&fs.ModeSticky != 0 {
		mode |= syscall.S_ISVTX
	}
	switch {
	case m.IsDir():
		mode |= syscall.S_IFDIR
	case m&fs.ModeSymlink != 0:
		mode |= syscall.S_IFLNK
	case m&fs.ModeNamedPipe != 0:
		mode |= syscall.S_IFIFO
	case m&fs.ModeSocket != 0:
		mode |= syscall.S_IFSOCK
	default:
		mode |= syscall.S_IFREG
	}
	return mode
}

// -----------------------------------------------------------------------------
// No exec, ever (same guarantee as forbid_exec() in launcher.c)
// -----------------------------------------------------------------------------

// forbidExec installs a seccomp filter that kills this process on execve or
// execveat, on system calls from a foreign ABI, and on x32 system calls. See
// forbid_exec() in launcher.c for the filter itself; it is identical.
//
// DIFFERENCE FROM THE C VERSION: the C FUSE process is single-threaded when
// it installs the filter. A Go process already has several threads before
// main() runs, and a seccomp filter normally applies only to the calling
// thread. SECCOMP_FILTER_FLAG_TSYNC applies it to every thread of the process
// at once (and the kernel copies no_new_privs to them along with it).
// Threads the runtime creates later inherit it.
func forbidExec() {
	// Both prctl/seccomp calls must happen on the same thread: the kernel
	// checks that the CALLING thread has no_new_privs.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	var arch uint32
	switch runtime.GOARCH {
	case "amd64":
		arch = unix.AUDIT_ARCH_X86_64
	case "arm64":
		arch = unix.AUDIT_ARCH_AARCH64
	default:
		fail("unsupported architecture %s: add its AUDIT_ARCH_* value", runtime.GOARCH)
	}

	stmt := func(code uint16, k uint32) unix.SockFilter {
		return unix.SockFilter{Code: code, K: k}
	}
	jump := func(code uint16, k uint32, jt, jf uint8) unix.SockFilter {
		return unix.SockFilter{Code: code, Jt: jt, Jf: jf, K: k}
	}
	const (
		ld   = unix.BPF_LD | unix.BPF_W | unix.BPF_ABS
		jeq  = unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K
		jge  = unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K
		ret  = unix.BPF_RET | unix.BPF_K
		kill = unix.SECCOMP_RET_KILL_PROCESS
		// Offsets into struct seccomp_data: int nr; __u32 arch; ...
		offNr   = 0
		offArch = 4
	)
	filter := []unix.SockFilter{
		stmt(ld, offArch),
		jump(jeq, arch, 1, 0),
		stmt(ret, kill),
		stmt(ld, offNr),
	}
	if runtime.GOARCH == "amd64" {
		filter = append(filter,
			jump(jge, 0x40000000 /* __X32_SYSCALL_BIT */, 0, 1),
			stmt(ret, kill))
	}
	filter = append(filter,
		jump(jeq, unix.SYS_EXECVE, 0, 1),
		stmt(ret, kill),
		jump(jeq, unix.SYS_EXECVEAT, 0, 1),
		stmt(ret, kill),
		stmt(ret, unix.SECCOMP_RET_ALLOW),
	)
	prog := unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}

	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		fail("cannot set no_new_privs: %v", err)
	}
	if _, _, errno := unix.Syscall(unix.SYS_SECCOMP, unix.SECCOMP_SET_MODE_FILTER,
		unix.SECCOMP_FILTER_FLAG_TSYNC, uintptr(unsafe.Pointer(&prog))); errno != 0 {
		fail("cannot install the seccomp filter: %v", errno)
	}
}
