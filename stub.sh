#!/usr/bin/env bash
# =============================================================================
# self-hoisted-nix launcher stub
# =============================================================================
#
# This file is the first part of a bundle produced by erofs-bundle.nix. The
# finished bundle is ONE file, laid out in 4 KiB blocks:
#
#   block 0 .. S-1          this shell script, padded with NUL bytes
#   block S .. S+B-1        a static (musl) `bwrap` binary, padded
#   block S+B .. S+B+F-1    a static (musl) `erofsfuse` binary, padded
#   block S+B+F .. end      an EROFS filesystem image whose root directory is
#                           the program's whole runtime closure, i.e. what
#                           would normally live under /nix/store
#
# The numbers S, B and F, the cache id and the path of the program to run are
# not known when this file is written. erofs-bundle.nix fills them in with
# nixpkgs' `substitute` helper, which replaces @name@-style placeholders. After
# that the stub has no references to anything that needs to exist on the host
# except bash (found through /usr/bin/env, so it need not be in /bin), a POSIX
# /bin/sh for the inner script, and a handful of standard tools (readlink,
# mkdir, mktemp, dd, chmod, mv, rm).
#
# What happens when you run the bundle:
#
#   1. The kernel sees "#!/usr/bin/env bash" on the first line and runs bash,
#      with the path of the bundle as the script to execute.
#   2. This script copies the two static helpers (bwrap, erofsfuse) out of
#      its own file into a per-user cache directory, once.
#   3. It uses bwrap to create a private sandbox (user + mount + PID
#      namespaces) whose filesystem looks like the host's, except that
#      /nix/store is an empty directory we control.
#   4. Inside the sandbox, erofsfuse mounts the EROFS image directly out of
#      the bundle file (at a byte offset, no extraction) onto /nix/store.
#   5. The real program is exec'd. Every /nix/store/... path baked into it
#      (interpreter, shared libraries, data files) now resolves.
#   6. When the program exits, the sandbox is torn down and the FUSE mount
#      and its daemon disappear with it.
#
# Why the binary payload after this script is harmless: bash reads a script in
# chunks and parses one command at a time, rather than parsing the whole file
# up front. The last command below is `exec`, which replaces the shell process
# with bwrap, so the shell never gets as far as the binary data. If `exec`
# itself fails (for example the helper is missing), a non-interactive shell
# exits right there, so the payload is never interpreted as shell code either
# way.
# =============================================================================

# -e: stop at the first command that fails, instead of carrying on in a broken
#     state (for example running bwrap after extraction failed).
# -u: treat use of an unset variable as an error, which catches typos and a
#     missing $HOME early.
# -o pipefail: a pipeline fails if any stage does, not just the last one.
set -euo pipefail

# -----------------------------------------------------------------------------
# Layout constants (filled in at build time)
# -----------------------------------------------------------------------------

# Block size used for all padding and offsets. It must match `bs` in
# erofs-bundle.nix. 4096 is also the EROFS block size and a typical page size,
# so the image starts on a nicely aligned boundary.
readonly bs=4096

# S = number of blocks taken up by this stub (including its NUL padding)
# B = number of blocks taken up by the static bwrap binary
# F = number of blocks taken up by the static erofsfuse binary
readonly S=@S@ B=@B@ F=@F@

# Byte offset where the EROFS image starts inside the bundle.
readonly image_offset=$(( (S + B + F) * bs ))

# -----------------------------------------------------------------------------
# Where are we?
# -----------------------------------------------------------------------------

# $0 is the path the kernel used to start this script. When run via $PATH it
# is the resolved path, and when run as ./foo it is relative. `readlink -f`
# turns it into an absolute path with every symlink resolved, so it stays
# valid after we change directories or namespaces. For example
# ./result/bin/jq becomes /nix/store/<hash>-jq-bundle/bin/jq.
self=$(readlink -f "$0")

# Per-user cache for the two extracted helper binaries.
#   - Follow the XDG spec: use $XDG_CACHE_HOME if the user set it.
#   - Otherwise use ~/.cache, the XDG default.
#   - If even $HOME is unset (some minimal cron or container environments),
#     fall back to /tmp/.cache rather than tripping `set -u`.
# The last path component is an id that erofs-bundle.nix derives by hashing
# the store paths of the exact bwrap and erofsfuse builds it embedded. So:
#   - every bundle built with the same helpers shares one cache entry, and
#   - a bundle with different helpers gets its own entry and never picks up
#     stale binaries from an older bundle.
cache=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/erofs-bundle/@id@

# -----------------------------------------------------------------------------
# Step 1: extract the static helpers (first run only)
# -----------------------------------------------------------------------------
#
# Why extract anything? The kernel can only execute a program that is a file
# of its own; it cannot start an ELF that sits in the middle of another file.
# bwrap and erofsfuse have to run *before* the EROFS image is mounted, so they
# cannot live inside the image either. They are small (about 2.3 MB together),
# so we copy them out once and reuse them. The big part, the image, is never
# copied; erofsfuse reads it in place from the bundle.
#
# We check for erofsfuse because the whole directory is moved into place in a
# single rename (see below). If erofsfuse is there, bwrap is too.
if [[ ! -x $cache/erofsfuse ]]; then
  # Make sure the parent directory (.../erofs-bundle) exists. `${cache%/*}`
  # strips the last path component, i.e. the id.
  mkdir -p "${cache%/*}"

  # Extract into a fresh temporary directory NEXT TO the final location, for
  # example ~/.cache/erofs-bundle/<id>.a8Xk2Q. Because it is on the same
  # filesystem, the final `mv` is an atomic rename. Another process will
  # therefore only ever see "no cache dir" or "complete cache dir", never a
  # half-written binary.
  tmp=$(mktemp -d "$cache.XXXXXX")

  # dd copies whole blocks, which is why everything in the bundle is padded
  # to 4 KiB boundaries:
  #   bs=$bs    read and write in 4096-byte blocks
  #   skip=N    skip the first N blocks of the input (the parts before the
  #             helper we want)
  #   count=M   copy exactly M blocks (the helper plus its padding)
  # stderr goes to /dev/null to hide dd's "records in/out" summary.
  #
  # The extracted files end with the NUL padding added at build time. That is
  # fine: the kernel ELF loader only maps the ranges listed in the ELF program
  # headers and never looks at bytes past them.
  #
  # bwrap sits right after the stub: skip S blocks, take B blocks.
  dd if="$self" of="$tmp/bwrap" bs=$bs skip=$S count=$B 2>/dev/null
  # erofsfuse sits right after bwrap: skip S+B blocks, take F blocks.
  dd if="$self" of="$tmp/erofsfuse" bs=$bs skip=$((S + B)) count=$F 2>/dev/null

  # dd creates plain files; make them executable.
  chmod 755 "$tmp/bwrap" "$tmp/erofsfuse"

  # Publish the directory with a single atomic rename, unless another copy of
  # the bundle that started at the same time already did.
  #
  # Honest caveat: if two first runs both pass the -e test at the same
  # instant, the second `mv` moves its temp dir INSIDE the first one's cache
  # dir (that is what mv does when the target is an existing directory). That
  # leaves a harmless stray subdirectory; both runs still find correct
  # binaries at $cache/bwrap and $cache/erofsfuse.
  [[ -e $cache ]] || mv "$tmp" "$cache"

  # If we lost the race above, our temp dir is still here; clean it up. If we
  # won, $tmp no longer exists and `rm -rf` quietly does nothing.
  rm -rf "$tmp"
fi

# -----------------------------------------------------------------------------
# Step 2: the script that runs INSIDE the sandbox
# -----------------------------------------------------------------------------
#
# bwrap can set up namespaces and mounts, but it cannot start a FUSE daemon
# for us. So the command we ask bwrap to run is a small shell script, held in
# this variable and passed to `/bin/sh -c`. It:
#   a. mounts the EROFS image onto /nix/store with erofsfuse, then
#   b. replaces itself with the real program.
#
# Why /bin/sh and not bash here: this script is plain POSIX and /bin/sh is the
# one interpreter every host is guaranteed to have at a fixed path, which is
# all bwrap can be given (there is no $PATH lookup for the sandbox command,
# and /usr/bin/env may or may not be where bash is).
#
# It gets its inputs as positional parameters (see the bwrap argument list
# further down). With `sh -c SCRIPT NAME ARG1 ARG2 ...`, NAME becomes $0 and
# the ARGs become $1, $2, ... inside SCRIPT:
#   $0  "sh"                     just a name for error messages
#   $1  path to erofsfuse        in the cache dir, visible in the sandbox
#   $2  byte offset of the image inside the bundle
#   $3  absolute path of the program in /nix/store
#   $4... the arguments the user passed to the bundle, untouched
#
# NOTE: this is a single-quoted string, so it must not contain a single quote
# (apostrophe) anywhere, comments included. It is also not expanded here, only
# later by the inner shell, so "$1" and friends below refer to the inner
# script arguments.
inner='
# Give the first three parameters readable names, then drop them with
# "shift 3" so that "$@" is exactly the user arguments.
fuse=$1 off=$2 main=$3; shift 3

# Mount the closure:
#   --offset=N      the image starts N bytes into the file, after the stub
#                   and the two helpers; erofsfuse reads it in place.
#   /.erofs-bundle  the bundle itself, bind-mounted read-only at this fixed
#                   path by bwrap (see below for why not use its real path).
#   /nix/store      an empty directory bwrap created for us to mount onto.
#
# Why this works without root or fusermount: inside our new user namespace
# we hold CAP_SYS_ADMIN (granted by --cap-add below), and the kernel lets
# FUSE be mounted from a user namespace. libfuse therefore calls mount(2)
# directly instead of needing the setuid fusermount helper.
#
# Without -f, erofsfuse puts itself in the background only AFTER the mount
# is in place. So once this command returns successfully, /nix/store is
# already populated and we can go ahead.
#
# erofsfuse prints a version banner and an "image mounted" notice every time.
# We capture all of its output instead of showing it, and only print it if
# the mount failed and the message is actually useful. Capturing with $(...)
# does not hang: when the daemon backgrounds itself it points its stdout and
# stderr at /dev/null, which closes our pipe.
if ! log=$("$fuse" --offset="$off" /.erofs-bundle /nix/store 2>&1); then
  printf "%s\nerofs-bundle: could not FUSE-mount closure at /nix/store\n" "$log" >&2
  exit 1
fi

# Become the real program. "exec" replaces this shell rather than running the
# program as a child, so:
#   - the program gets our PID, stdin/stdout/stderr and environment,
#   - signals (Ctrl-C) reach it directly, and
#   - its exit status becomes the exit status bwrap reports, which is also
#     the exit status of the whole bundle.
exec "$main" "$@"
'

# -----------------------------------------------------------------------------
# Step 3: build the bwrap argument list
# -----------------------------------------------------------------------------
#
# Everything bwrap needs goes into one array. Quoting inside "${argv[@]}" is
# per element, so paths with spaces or glob characters survive untouched, and
# appending is just `argv+=( ... )`. The user's own arguments are not part of
# it: they stay in "$@" and are appended at the very end of the final exec,
# which is exactly where the inner script expects them.
#
# Namespaces and basic mounts:
#   --unshare-user     Create a new user namespace. We become the owner of
#                      it, which is what lets an unprivileged user do the
#                      mounts below. bwrap maps our real uid/gid to the same
#                      numbers inside, so the program still sees who you are.
#   --unshare-pid      Create a new PID namespace. bwrap becomes its PID 1 and
#                      the program runs as its child. When the program exits,
#                      PID 1 exits, and the kernel kills every other process
#                      in the namespace. That includes the backgrounded
#                      erofsfuse daemon, so nothing lingers after the run.
#                      Side effect: the program cannot see host processes.
#   --die-with-parent  If the process that launched the sandbox dies, the
#                      kernel sends the sandbox SIGKILL (PR_SET_PDEATHSIG), so
#                      killing the bundle never leaves orphans behind.
#   --cap-add CAP_SYS_ADMIN
#                      Keep CAP_SYS_ADMIN for the command we run, so the inner
#                      script can call mount(2) for FUSE. The capability only
#                      counts inside our own user namespace; it gives no power
#                      over the host. Unprivileged bwrap only allows this
#                      together with --unshare-user, for exactly that reason.
#   --dev-bind /dev /dev
#                      Bind the host /dev into the sandbox WITH device access
#                      (plain --bind would add "nodev"). We need /dev/fuse,
#                      and the program probably wants /dev/null, /dev/tty,
#                      /dev/urandom and so on.
#   --proc /proc       Mount a fresh procfs that matches the new PID namespace,
#                      so /proc/self and friends describe the sandbox.
#                      Mounting it is allowed because we own that namespace.
argv=(
  --unshare-user
  --unshare-pid
  --die-with-parent
  --cap-add CAP_SYS_ADMIN
  --dev-bind /dev /dev
  --proc /proc
)

# Rebuild the host root directory inside the sandbox.
#
# bwrap starts from an EMPTY root (a tmpfs). We cannot just bind the whole
# host / onto it, because we need to put our own /nix/store in place, and
# creating /nix on a host that does not have it would need write access to
# the real /. So we recreate the host root one top-level entry at a time,
# minus the ones we handle ourselves:
#   /nix   replaced by our own /nix/store (on a Nix host, the host store is
#          hidden inside the sandbox)
#   /proc  already mounted fresh above
#   /dev   already bound above
# Note: the glob /* does not match names starting with a dot. Nothing
# important lives there.
declare -A handled=([/nix]=1 [/proc]=1 [/dev]=1)
for d in /*; do
  if [[ -n ${handled[$d]:-} ]]; then
    continue
  elif [[ -L $d ]]; then
    # Top-level symlink, e.g. on merged-/usr distros /bin -> usr/bin and
    # /lib -> usr/lib. Recreate it as the same symlink (same target text) so
    # paths resolve exactly as on the host, including the dynamic loader
    # path. We rely on that below to run /bin/sh.
    argv+=(--symlink "$(readlink "$d")" "$d")
  elif [[ -d $d ]]; then
    # Real directory: bind-mount it at the same path, read-write like on the
    # host. bwrap binds recursively, so mounts below it (e.g. /home on its
    # own partition, /run/user/<uid>, /sys/fs/cgroup) come along too.
    argv+=(--bind "$d" "$d")
  fi
  # Anything else at the top level (e.g. a /swap.img file) is not needed by
  # programs and is skipped.
done

# Final setup steps and the command to run. bwrap applies these after the
# ones above, in this order.
#
#   --ro-bind "$self" /.erofs-bundle
#       Make the bundle file available at a fixed path inside the sandbox.
#       We cannot rely on its real path: if the bundle itself lives under
#       /nix/store (for example when started as ./result/bin/jq), that path
#       is exactly what gets hidden behind our new /nix/store. bwrap creates
#       an empty file /.erofs-bundle on the tmpfs root to mount over.
#       Read-only because nothing should ever write to it.
#   --dir /nix/store
#       Create the empty mount point for the image (and /nix above it) on the
#       tmpfs root.
argv+=(--ro-bind "$self" /.erofs-bundle --dir /nix/store)

#   --
#       End of bwrap options; everything after it is the command to run.
#   /bin/sh -c "$inner" sh
#       Run the inner script from step 2 with the host shell. /bin/sh is
#       reachable because /bin (or its symlink to usr/bin) was recreated
#       above. "sh" becomes the inner $0.
#   "$cache/erofsfuse"                 inner $1
#       The cache is under $HOME (or $XDG_CACHE_HOME, or /tmp), all of
#       which were bound above, so the same path works inside.
#   "$image_offset"                    inner $2
#       Byte offset where the EROFS image starts in the bundle.
#   the program path (placeholder)     inner $3
#       Filled in at build time from `exe` in erofs-bundle.nix. It is left
#       unquoted on purpose: substitute inserts it already shell-quoted, so
#       it becomes exactly one array element.
argv+=(-- /bin/sh -c "$inner" sh "$cache/erofsfuse" "$image_offset" @main@)

# -----------------------------------------------------------------------------
# Step 4: go
# -----------------------------------------------------------------------------
#
# Replace this shell with bwrap, passing our argument list followed by the
# user's own arguments ("$@", untouched since the script started). From here
# on:
#   bwrap (outer)   sets up the namespaces and mounts listed above, then
#   bwrap (PID 1)   waits in the new PID namespace for its child,
#   /bin/sh -c      the inner script mounts /nix/store and execs
#   the program     which runs with its whole closure present.
# bwrap exits with the program's exit status, so `bundle; echo $?` behaves as
# if you had run the program directly.
#
# This is the last line the shell ever reads: the binary payload that
# follows in the file is never parsed (see the header).
exec "$cache/bwrap" "${argv[@]}" "$@"
