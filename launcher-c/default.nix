# The generic bundle launcher: one static executable that does the namespace
# setup itself and has erofs-utils' FUSE server linked in. Call this with
# pkgsStatic.callPackage so that every dependency is a static (musl) build.
{
  stdenv,
  pkg-config,
  erofs-utils,
  fuse3,
  lz4,
  zstd,
  xz,
  zlib,
  libdeflate,
  util-linux,
  xxhash,
}:

let
  # nixpkgs' preConfigure points libfuse's mount_util.c at util-linux's
  # mount/umount by store path. The launcher never runs that code: it mounts
  # FUSE itself and forbids exec in the FUSE process (see mount_fuse() and
  # forbid_exec() in launcher.c). But the code is still linked, and those
  # dead strings would be store references. So keep upstream's /bin/mount
  # and /bin/umount. (The other substitution there only touches the
  # mount.fuse3 program, which we do not link.)
  fuse3-portable = fuse3.overrideAttrs { preConfigure = ""; };

  # --enable-static-fuse additionally installs liberofsfuse.a: erofsfuse's
  # main.c compiled with -Dmain=erofsfuse_main, plus all of liberofs.
  erofsfuse-lib = (erofs-utils.override { fuse3 = fuse3-portable; }).overrideAttrs (old: {
    configureFlags = old.configureFlags ++ [ "--enable-static-fuse" ];
  });
in
stdenv.mkDerivation {
  pname = "self-hoisted-launcher";
  version = "1";

  src = ./launcher.c;
  dontUnpack = true;

  # Proof that the launcher is self-contained: Nix fails the build if the
  # output mentions ANY store path (it scans the file for the hash of every
  # path in the build's input closure). The launcher runs before /nix/store
  # is mounted, so it must not need anything from there.
  __structuredAttrs = true;
  outputChecks.out.allowedReferences = [ ];

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    erofsfuse-lib
    fuse3-portable
    lz4
    zstd
    xz
    zlib
    libdeflate
    util-linux # libuuid
    xxhash
  ];

  # --wrap=fuse_daemonize routes erofsfuse_main()'s call to fuse_daemonize()
  # to __wrap_fuse_daemonize() in launcher.c, our "mount is ready" hook.
  buildPhase = ''
    runHook preBuild
    $CC -std=gnu11 -O2 -Wall -Wextra -static -o launcher $src \
      -L${erofsfuse-lib}/lib -lerofsfuse \
      $($PKG_CONFIG --static --libs fuse3 liblz4 libzstd liblzma zlib libdeflate uuid libxxhash) \
      -lpthread \
      -Wl,--wrap=fuse_daemonize
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 launcher $out/bin/self-hoisted-launcher
    runHook postInstall
  '';

  # pkgsStatic's stdenv records every buildInput in
  # nix-support/propagated-build-inputs, so that static libraries pass their
  # own dependencies on to whatever links them. Nothing links against the
  # launcher, and that file would be its only store reference.
  postFixup = ''
    rm -r $out/nix-support
  '';

  meta.mainProgram = "self-hoisted-launcher";
}
