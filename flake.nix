{
  description = "Nix flake for Polaris game streaming host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.callPackage ./nix/package.nix { };
          polaris-stream = self.packages.${system}.default;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/polaris";
          meta.description = "Run Polaris";
        };
        polaris-stream = self.apps.${system}.default;
      });

      checks = forAllSystems (
        system:
        import ./nix/checks.nix {
          inherit self nixpkgs system;
          pkgs = import nixpkgs { inherit system; };
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt-tree
      );

      overlays.default = final: _prev: {
        polaris-stream = final.callPackage ./nix/package.nix { };
      };

      nixosModules.default = { pkgs, ... }: {
        imports = [
          (import ./nix/module.nix {
            defaultPackage = pkgs.callPackage ./nix/package.nix { };
          })
        ];
      };
    };
}
