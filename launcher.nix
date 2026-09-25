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
  # --enable-static-fuse additionally installs liberofsfuse.a: erofsfuse's
  # main.c compiled with -Dmain=erofsfuse_main, plus all of liberofs.
  erofsfuse-lib = erofs-utils.overrideAttrs (old: {
    configureFlags = old.configureFlags ++ [ "--enable-static-fuse" ];
  });
in
stdenv.mkDerivation {
  pname = "self-hoisted-launcher";
  version = "1";

  src = ./launcher.c;
  dontUnpack = true;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    erofsfuse-lib
    fuse3
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

  meta.mainProgram = "self-hoisted-launcher";
}
