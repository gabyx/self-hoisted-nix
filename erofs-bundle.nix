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
  jq,
  pkgsStatic,
}:

let
  defaultLauncher = pkgsStatic.callPackage ./launcher.nix { };
in
{
  drv,
  exe ? lib.getExe drv,
  # The file name of the bundle. It defaults to the program's own name, because
  # the launchers treat a bundle started as X like the closure's bin/X
  # (multi-call support): Lix ships both bin/nix and bin/lix.
  name ? builtins.unsafeDiscardStringContext (baseNameOf exe),
  # Any launcher that reads the trailer format: launcher.c (default), or
  # the Go one in ./launcher-go (which needs mkfsFlags = [ ], see launcher-go/main.go).
  launcher ? defaultLauncher,
  # Extra mkfs.erofs flags, i.e. the compression.
  mkfsFlags ? [ "-zlz4hc" ],
}:

let
  closure = closureInfo { rootPaths = [ drv ]; };

  # Image root == contents of /nix/store, so it can be mounted directly there.
  # Same recipe as nixpkgs' nixos/lib/erofs-store-image.nix, plus mkfsFlags.
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
            ${lib.escapeShellArgs mkfsFlags} \
            --hard-dereference \
            --tar=f \
            $out
      '';
  # The bundle as Nix sees it without any help: Nix scans it and records a
  # reference for every store path hash it finds. That reference list is the
  # ground truth the proof below checks.
  unchecked = runCommand "${name}-bundle-unchecked" { } ''
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
  '';
in
# The bundle can't pass `allowedReferences = [ ]` as it stands: its image
# consists of store paths, so Nix finds their hashes in it. What must hold is
# that every path it references is one it carries itself. This derivation
# proves that from Nix's own reference graph of `unchecked`, then publishes
# the same file with references discarded, so Nix no longer thinks the bundle
# needs anything from a store.
runCommand "${name}-bundle"
  {
    __structuredAttrs = true;
    exportReferencesGraph.unchecked = [ unchecked ];
    unsafeDiscardReferences.out = true;
    nativeBuildInputs = [
      jq
      erofs-utils
    ];
    passthru = {
      inherit
        image
        closure
        launcher
        unchecked
        ;
    };
    meta.mainProgram = name;
  }
  ''
    bundle=${unchecked}/bin/${name}

    # 1. Every store path Nix found in the bundle (minus the bundle itself).
    jq -r '.unchecked[].path' "$NIX_ATTRS_JSON_FILE" \
      | grep -vxF ${unchecked} | sort -u > referenced

    # 2. Every store path the bundle actually serves: the top-level entries
    #    of the EROFS image, read out of the bundle file itself at the offset
    #    its trailer names, i.e. exactly what the launcher mounts.
    offset=$(tail -c 4096 "$bundle" | tr -d '\0' | sed -n 's/^image-offset //p')
    dump.erofs --offset="$offset" --ls --path=/ "$bundle" \
      | awk 'f && $3 != "." && $3 != ".." { print "${builtins.storeDir}/" $3 } /NID TYPE/ { f = 1 }' \
      | sort -u > served

    # 3. Referenced but not served is exactly the set of paths the bundle
    #    would need from somewhere else. It must be empty.
    comm -23 referenced served > missing
    if [ -s missing ]; then
      echo "error: the bundle references store paths its image does not contain:" >&2
      cat missing >&2
      exit 1
    fi
    echo "proof: all $(wc -l < referenced) store paths referenced by the bundle are served by its image ($(wc -l < served) paths)"

    mkdir -p $out/bin
    cp "$bundle" $out/bin/${name}
    chmod 555 $out/bin/${name}
  ''
