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
          launcher = pkgs.pkgsStatic.callPackage ./launcher.nix { };
          jq = mkErofsBundle { drv = pkgs.jq; };
          python3 = mkErofsBundle {
            drv = pkgs.python3;
            name = "python3";
          };
          lix = mkErofsBundle { drv = pkgs.lix; };

          # The Go launcher, side by side. No pure-Go EROFS reader can read
          # compressed images yet, so these use an uncompressed one.
          launcher-go = pkgs.callPackage ./go-launcher.nix { };
          jq-go = mkErofsBundle {
            drv = pkgs.jq;
            launcher = self.packages.${system}.launcher-go;
            mkfsFlags = [ ];
          };
          python3-go = mkErofsBundle {
            drv = pkgs.python3;
            name = "python3";
            launcher = self.packages.${system}.launcher-go;
            mkfsFlags = [ ];
          };
        }
      );
    };
}
