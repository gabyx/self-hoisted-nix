# Build a single executable file that carries a program's entire runtime
# closure as an EROFS image and mounts it at /nix/store on demand.
#
# Output file layout, in 4 KiB blocks:
#
#   [ sh stub ][ static bwrap ][ static erofsfuse ][ EROFS image ]
#
# At run time the stub extracts the two static helpers to a cache dir, enters
# an unprivileged user+mount+pid namespace (bwrap), FUSE-mounts the image
# straight out of the file (erofsfuse --offset) at /nix/store, and execs the
# program. Nothing on the host needs /nix, root, or a setuid helper.
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
  bwrap = "${pkgsStatic.bubblewrap}/bin/bwrap";
  erofsfuse = "${pkgsStatic.erofs-utils}/bin/erofsfuse";

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
    passthru = { inherit image closure; };
    meta.mainProgram = name;
  }
  ''
    bs=4096
    blocks() { echo $(( ($(stat -c %s "$1") + bs - 1) / bs )); }

    S=4
    B=$(blocks ${bwrap})
    F=$(blocks ${erofsfuse})
    id=$(echo ${bwrap} ${erofsfuse} | sha256sum | cut -c1-16)

    substitute ${./stub.sh} stub \
      --subst-var-by main ${lib.escapeShellArg exe} \
      --subst-var-by id "$id" \
      --subst-var-by S "$S" \
      --subst-var-by B "$B" \
      --subst-var-by F "$F"

    if [ "$(stat -c %s stub)" -gt $((S * bs)) ]; then
      echo "stub.sh is larger than $S blocks; bump S" >&2
      exit 1
    fi

    install -m644 stub           p0 && truncate -s $((S * bs)) p0
    install -m644 ${bwrap}       p1 && truncate -s $((B * bs)) p1
    install -m644 ${erofsfuse}   p2 && truncate -s $((F * bs)) p2

    mkdir -p $out/bin
    cat p0 p1 p2 ${image} > $out/bin/${name}
    chmod 555 $out/bin/${name}
  ''
