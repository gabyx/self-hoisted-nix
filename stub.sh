#!/bin/sh
# Self-mounting Nix closure (see erofs-bundle.nix). Everything after this
# script is binary payload; the shell never reads past the final `exec`.
set -eu

bs=4096
S=@S@ B=@B@ F=@F@
self=$(readlink -f "$0")
cache=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/erofs-bundle/@id@

if [ ! -x "$cache/erofsfuse" ]; then
  mkdir -p "${cache%/*}"
  tmp=$(mktemp -d "$cache.XXXXXX")
  dd if="$self" of="$tmp/bwrap" bs=$bs skip=$S count=$B 2>/dev/null
  dd if="$self" of="$tmp/erofsfuse" bs=$bs skip=$((S + B)) count=$F 2>/dev/null
  chmod 755 "$tmp/bwrap" "$tmp/erofsfuse"
  [ -e "$cache" ] || mv "$tmp" "$cache"
  rm -rf "$tmp"
fi

# Runs inside the sandbox: mount the image, then become the program.
inner='
fuse=$1 off=$2 main=$3; shift 3
if ! log=$("$fuse" --offset="$off" /.erofs-bundle /nix/store 2>&1); then
  printf "%s\nerofs-bundle: could not FUSE-mount closure at /nix/store\n" "$log" >&2
  exit 1
fi
exec "$main" "$@"
'

# Build bwrap's argv after the user's args, then rotate the user's args to
# the end (POSIX sh has no arrays).
n=$#
set -- "$@" --unshare-user --unshare-pid --die-with-parent \
  --cap-add CAP_SYS_ADMIN \
  --dev-bind /dev /dev --proc /proc
# Recreate the host's top-level dirs on bwrap's tmpfs root, minus /nix.
for d in /*; do
  case $d in /nix | /proc | /dev) continue ;; esac
  if [ -L "$d" ]; then
    set -- "$@" --symlink "$(readlink "$d")" "$d"
  elif [ -d "$d" ]; then
    set -- "$@" --bind "$d" "$d"
  fi
done
set -- "$@" --ro-bind "$self" /.erofs-bundle --dir /nix/store \
  -- /bin/sh -c "$inner" sh \
  "$cache/erofsfuse" $(((S + B + F) * bs)) @main@
while [ "$n" -gt 0 ]; do
  set -- "$@" "$1"
  shift
  n=$((n - 1))
done

exec "$cache/bwrap" "$@"
