# self-hoisted-nix

Turn any Nix-built program into a **single executable file** that runs on a
Linux host without Nix: no `/nix`, no root, no setuid helper.

The file carries the program's full runtime closure as an
[EROFS](https://erofs.docs.kernel.org/) image. When you run it, it mounts that
image at `/nix/store` in a private namespace and runs the program.

```console
$ nix build .#jq
$ echo '{"a":[1,2,3]}' | ./result/bin/jq '.a | add'
6
$ scp result/bin/jq some-host-without-nix:
```

## Usage

Bundles included as examples:

| Attribute         | Store paths | Closure | EROFS (lz4hc) |
| ----------------- | ----------- | ------- | ------------- |
| `.#jq` (default)  | 7           | 37 MB   | 21 MB         |
| `.#python3`       | 23          | 209 MB  | 130 MB        |

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

The EROFS image and closure list are exposed as `passthru.image` and
`passthru.closure`.

## How it works

### Building the image (`erofs-bundle.nix`)

1. `closureInfo` lists every store path the program needs at runtime.
2. `tar` packs those paths with the `/nix/store/` prefix stripped, then
   `mkfs.erofs --tar=f -zlz4hc` turns the stream into an image whose root *is*
   the store. This follows nixpkgs' `nixos/lib/erofs-store-image.nix`, with
   compression added. The build is reproducible: timestamp, UUID and file
   owners are fixed.
3. The output file is laid out in 4 KiB blocks:

   ```
   [ sh stub ][ static bwrap ][ static erofsfuse ][ EROFS image ]
   ```

   `bwrap` and `erofsfuse` come from `pkgsStatic` (musl), so they run on any
   Linux host.

### At run time (`stub.sh`)

1. On first run, copy the two static helpers (about 2.3 MB) out of the file
   into `~/.cache/erofs-bundle/<id>/`.
2. Use `bwrap` to enter an unprivileged user, mount and PID namespace. The host's
   top-level directories are rebuilt on a tmpfs root, leaving out `/nix`.
3. Use `erofsfuse --offset=…` to mount the image straight out of the file at
   `/nix/store`. Nothing is extracted.
4. Run the program. When it exits, the PID namespace is torn down and the
   FUSE daemon goes with it.

The launcher uses FUSE because the in-kernel EROFS driver can't be mounted
without root, even inside a user namespace.

## Requirements and limitations

- **The host needs unprivileged user namespaces and `/dev/fuse`** (Linux ≥ 4.18).
  This is *not* available by default on:
  - Ubuntu 24.04+ (`kernel.apparmor_restrict_unprivileged_userns=1`)
  - many Docker containers
  - hardened kernels

  If you have root on such a host, you can loop-mount the image with the kernel
  driver instead: `mount -t erofs -o loop,offset=<N> ./bundle /nix/store`. Here
  `N` is the image offset, `(S + B + F) * 4096`, using the block counts written
  into the stub.
- **Sandbox side effects:**
  - The program runs in its own PID namespace, so it can't see host processes.
  - It holds `CAP_SYS_ADMIN` inside its own user namespace. That gives it no
    power over the host.
- **The host's `/nix` is hidden inside the sandbox.** On a Nix or NixOS host,
  run the store path directly instead.
- **Each bundle is tied to one architecture.** The flake defines
  `x86_64-linux` and `aarch64-linux`.
- **FUSE is slower than the in-kernel driver.** That matters only for
  I/O-heavy programs.
- **Size vs. startup:** `-zlzma` or `-zzstd` give smaller files; lz4hc
  decompresses fastest.
