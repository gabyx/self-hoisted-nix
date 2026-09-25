# self-hoisted-nix

Turn any Nix-built program into a **single static executable** that runs on a
Linux host without Nix: no `/nix`, no root, no setuid helper, not even
`/bin/sh`.

The file carries the program's full runtime closure as an
[EROFS](https://erofs.docs.kernel.org/) image. When you run it, it mounts that
image at `/nix/store` in a private namespace and runs the program. Nothing is
extracted or written to disk.

```console
$ nix build .#jq
$ echo '{"a":[1,2,3]}' | ./result/bin/jq '.a | add'
6
$ scp result/bin/jq some-host-without-nix:
```

## Usage

Bundles included as examples:

| Attribute         | Store paths | Closure | Bundle  |
| ----------------- | ----------- | ------- | ------- |
| `.#jq` (default)  | 7           | 37 MB   | 22 MB   |
| `.#python3`       | 23          | 209 MB  | 138 MB  |

`.#launcher` is the bare launcher (about 2 MB) that every bundle starts with.

Bundle your own package from another flake:

```nix
{
  inputs.self-hoisted-nix.url = "github:gabyx/self-hoisted-nix";

  outputs = { self, nixpkgs, self-hoisted-nix }: {
    packages.x86_64-linux.default =
      self-hoisted-nix.lib.x86_64-linux.mkErofsBundle {
        drv = nixpkgs.legacyPackages.x86_64-linux.ripgrep;
        # exe  ? lib.getExe drv   -- program to run
        # name ? lib.getName drv  -- name of the output file
      };
  };
}
```

The EROFS image, closure list, launcher and unproven bundle are exposed as
`passthru.image`, `passthru.closure`, `passthru.launcher` and
`passthru.unchecked`.

## How it works

### The bundle file

```
[ static launcher, padded to 4 KiB ][ EROFS image ][ 4 KiB text trailer ]
```

- **The launcher** (`launcher.c`, built by `launcher.nix`) is a fully static
  musl executable. It sits at byte 0, so the bundle itself is the executable.
  The kernel only loads the parts of the file the ELF headers name, and never
  looks at the image or trailer behind it. The launcher is generic: it is
  built once, and each bundle just appends a different image and trailer.
- **The image** is built by `erofs-bundle.nix`. `closureInfo` lists the
  runtime closure. `tar` packs it with the `/nix/store/` prefix stripped, and
  `mkfs.erofs --tar=f -zlz4hc` turns that into an image whose root *is* the
  store. This follows nixpkgs' `nixos/lib/erofs-store-image.nix`, with
  compression added. The build is reproducible: timestamp, UUID and file
  owners are fixed.
- **The trailer** is plain text, so `tail -c 4096 bundle` shows it:

  ```
  self-hoisted-nix v1
  image-offset 2109440
  image-size 21016576
  exec /nix/store/…-jq-1.8.2-bin/bin/jq
  ```

### At run time

The launcher contains the namespace setup that `bwrap` used to do, plus
erofs-utils' complete FUSE server. The server is linked in from
`liberofsfuse.a`, which is erofs-utils built with `--enable-static-fuse`. Four
processes take part:

1. **OUTER** is the process you started. It reads the trailer and creates new
   user, mount and PID namespaces, which needs no privileges. Then it waits,
   forwards signals, and finally exits exactly the way the program did: same
   exit code, or death by the same signal.
2. **INIT** is PID 1 of the new PID namespace. It builds a new root on a tmpfs
   by bind-mounting each of the host's top-level directories, except `/nix`,
   and mounting a fresh `/proc`. Then it creates an empty `/nix/store` and
   makes the root read-only.
3. **FUSE** runs `erofsfuse_main()`, which mounts the image straight out of the
   bundle file (`--offset=<image-offset>`) onto `/nix/store`. The launcher is
   linked with `-Wl,--wrap=fuse_daemonize`: libfuse calls that function right
   after the mount succeeds, so the replacement tells INIT "ready" instead of
   forking into the background.
4. **PROGRAM** `exec`s the real program in the original working directory,
   with `no_new_privs` set and no capabilities.

When the program exits, INIT exits too. When PID 1 of a namespace exits, the
kernel kills everything else in it, so the FUSE server and the mount disappear.
Killing OUTER, even with `kill -9`, takes the whole sandbox down.

Signal handling:
- Signals sent deliberately with `kill`, `timeout` or a service manager are
  forwarded to the program once.
- Ctrl-C and other terminal signals reach the program directly, and are not
  forwarded a second time.
- The FUSE server runs in its own process group, so Ctrl-C can't unmount the
  store while the program is still handling it.

If the launcher can't set up the sandbox, it prints a `self-hoisted-nix:`
error and exits with 127.

The launcher uses FUSE because the in-kernel EROFS driver can't be mounted
without root, even inside a user namespace.

### Proof that nothing comes from the host's `/nix/store`

Both checks run during `nix build`, and the build fails if either one fails.

1. **The launcher references no store paths at all.** `launcher.nix` sets
   `__structuredAttrs = true` and `outputChecks.out.allowedReferences = [ ]`,
   so Nix itself rejects the build if the file mentions the hash of any path in
   its build closure. The launcher is the only code that runs before
   `/nix/store` is mounted, so it must not need anything from there.
   Getting it to pass took two fixes, both explained in `launcher.nix`:
   - nixpkgs' `fuse3` hardcodes util-linux's `mount`/`umount` by store path.
   - `pkgsStatic` writes a `nix-support/propagated-build-inputs` file.
2. **The bundle references only paths its own image serves.** A bundle can't
   pass `allowedReferences = [ ]`: its image *is* store paths, so Nix finds
   their hashes in it. The check is instead done in two steps:
   - `passthru.unchecked` is built normally, so Nix computes its references.
   - The final derivation reads that reference graph through
     `exportReferencesGraph`, which is available because it uses
     `__structuredAttrs`. It lists the top level of the EROFS image straight
     out of the bundle file with `dump.erofs --offset`, and fails if anything
     is referenced but not served.

   For example, a bundle whose `exe` points outside `drv`'s closure fails with
   `the bundle references store paths its image does not contain`. Once the
   proof passes, the final output sets `unsafeDiscardReferences.out = true`,
   so Nix records no store dependencies for it.

```console
$ nix path-info -rSh .#jq
/nix/store/…-jq-bundle	  22.1M
```

## Requirements and limitations

- **The host needs unprivileged user namespaces and `/dev/fuse`** (Linux ≥ 4.18).
  This is *not* available by default on:
  - Ubuntu 24.04+ (`kernel.apparmor_restrict_unprivileged_userns=1`)
  - many Docker containers
  - hardened kernels

  If you have root on such a host, you can loop-mount the image with the kernel
  driver instead, taking the offset from the trailer:
  `mount -t erofs -o loop,offset=<image-offset> ./bundle /nix/store`.
- **Sandbox side effects:**
  - The program runs in its own PID namespace, so it can't see host processes.
  - The top level of `/` is read-only. Everything below it, like `/home` and
    `/tmp`, is the host's, with the host's permissions.
  - `setuid` binaries don't gain privileges (`no_new_privs`).
- **Duplicate signals:** a signal sent to the whole process group, such as
  `kill -TERM -<pgid>` or systemd stopping a service, reaches the program both
  directly and through forwarding, so it may arrive twice.
- **The host's `/nix` is hidden inside the sandbox.** On a Nix or NixOS host,
  run the store path directly instead.
- **Each bundle is tied to one architecture.** The flake defines
  `x86_64-linux` and `aarch64-linux`.
- **FUSE is slower than the in-kernel driver.** That matters only for
  I/O-heavy programs.
- **Size vs. startup:** `-zlzma` or `-zzstd` give smaller images; lz4hc
  decompresses fastest.
