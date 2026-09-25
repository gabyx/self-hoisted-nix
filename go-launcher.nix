# The Go version of the bundle launcher (see launcher-go/main.go), side by side with
# launcher.nix. Pure Go with cgo disabled, so the binary is static and needs
# no libc.
{
  lib,
  buildGoModule,
  go,
}:

let
  # nixpkgs patches its Go standard library to look in /nix/store: `net`
  # reads @iana-etc@/etc/protocols and /etc/services INSTEAD of the host's,
  # `time` tries @tzdata@/share/zoneinfo before /usr/share/zoneinfo, and
  # `mime` tries @mailcap@ first. Every Go binary built by nixpkgs carries
  # those store paths, and on a host without Nix the iana-etc ones just point
  # nowhere. The launcher must not reference the store (its outputChecks
  # below caught exactly this), so build it with upstream Go's behaviour.
  go-portable = go.overrideAttrs (old: {
    patches = lib.filter (
      p:
      !lib.any (prefix: lib.hasPrefix prefix (p.name or "")) [
        "iana-etc"
        "tzdata"
        "mailcap"
      ]
    ) old.patches;
  });
in
(buildGoModule.override { go = go-portable; }) {
  pname = "self-hoisted-launcher-go";
  version = "1";

  src = ./launcher-go;
  vendorHash = "sha256-c4HY5auBo4NWmot/cudqR2XDnxzVe6weD4REYVZAlc4=";

  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
  ];

  # Same proof as the C launcher: Nix fails the build if the binary mentions
  # any store path. It runs before /nix/store is mounted.
  __structuredAttrs = true;
  outputChecks.out.allowedReferences = [ ];

  postInstall = ''
    mv $out/bin/launcher $out/bin/self-hoisted-launcher-go
  '';

  meta.mainProgram = "self-hoisted-launcher-go";
}
