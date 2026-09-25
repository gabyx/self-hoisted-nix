{
  description = "Pack a Nix closure into a single self-mounting EROFS executable";

  inputs.nixpkgs.url = "nixpkgs";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      lib = forAllSystems (
        system: { mkErofsBundle = nixpkgs.legacyPackages.${system}.callPackage ./erofs-bundle.nix { }; }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.lib.${system}) mkErofsBundle;
        in
        {
          default = self.packages.${system}.jq;
          jq = mkErofsBundle { drv = pkgs.jq; };
          python3 = mkErofsBundle { drv = pkgs.python3; };
        }
      );
    };
}
