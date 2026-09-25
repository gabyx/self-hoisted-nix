# Build a single executable file that carries a program's entire runtime
# closure as an EROFS image and mounts it at /nix/store on demand.
#
# Output file layout:
#
#   [ static launcher, padded to 4 KiB ][ EROFS image ][ 4 KiB text trailer ]
#
# The launcher (launcher.c) is generic and built once. It reads the trailer
# at the end of its own file to find the image and the program, enters an
# unprivileged user+mount+pid namespace, FUSE-mounts the image straight out
# of the file at /nix/store with erofsfuse linked in, and execs the program.
# Nothing on the host needs /nix, root, a shell, or a setuid helper.
{
  lib,
  runCommand,
  closureInfo,
  gnutar,
  erofs-utils,
  pkgsStatic,
}:

{
  drv,
  exe ? lib.getExe drv,
  name ? lib.getName drv,
}:

let
  launcher = pkgsStatic.callPackage ./launcher.nix { };

  closure = closureInfo { rootPaths = [ drv ]; };

  # Image root == contents of /nix/store, so it can be mounted directly there.
  # Same recipe as nixpkgs' nixos/lib/erofs-store-image.nix, plus compression.
  image =
    runCommand "${name}-closure.erofs"
      {
        nativeBuildInputs = [
          gnutar
          erofs-utils
        ];
      }
      ''
        tar --create \
          --absolute-names \
          --verbatim-files-from \
          --transform 'flags=rSh;s|/nix/store/||' \
          --files-from ${closure}/store-paths \
          | mkfs.erofs \
            --quiet \
            --force-uid=0 \
            --force-gid=0 \
            -T 0 \
            -U 00000000-0000-0000-0000-000000000000 \
            -zlz4hc \
            --hard-dereference \
            --tar=f \
            $out
      '';
in
runCommand "${name}-bundle"
  {
    passthru = { inherit image closure launcher; };
    meta.mainProgram = name;
  }
  ''
    bs=4096

    # Launcher, padded so the image starts on a 4 KiB boundary (nice for a
    # loop mount; erofsfuse itself would accept any offset).
    install -m644 ${lib.getExe launcher} head
    truncate -s $(( ($(stat -c %s head) + bs - 1) / bs * bs )) head

    # The trailer format is parsed by read_trailer() in launcher.c.
    printf 'self-hoisted-nix v1\nimage-offset %s\nimage-size %s\nexec %s\n' \
      "$(stat -c %s head)" "$(stat -c %s ${image})" ${lib.escapeShellArg exe} \
      > trailer
    if [ "$(stat -c %s trailer)" -gt $bs ]; then
      echo "trailer longer than $bs bytes" >&2
      exit 1
    fi
    truncate -s $bs trailer

    mkdir -p $out/bin
    cat head ${image} trailer > $out/bin/${name}
    chmod 555 $out/bin/${name}
  ''
