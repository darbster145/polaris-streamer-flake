{
  description = "Nix flake for Polaris game streaming host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.callPackage ./nix/package.nix { };
          polaris-stream = self.packages.${system}.default;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/polaris";
          meta.description = "Run Polaris";
        };
      });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          moduleEval = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                services.polaris-stream = {
                  enable = true;
                  openFirewall = true;
                  settings.encoder = "vaapi";
                };
              }
            ];
          };
        in {
          package = self.packages.${system}.default;
          module = pkgs.runCommand "polaris-stream-module-check" { } ''
            test "${toString moduleEval.config.services.polaris-stream.settings.port}" = "47989"
            test "${toString (builtins.elem 47990 moduleEval.config.networking.firewall.allowedTCPPorts)}" = "1"
            touch $out
          '';
        });

      nixosModules.default = { pkgs, ... }: {
        imports = [
          (import ./nix/module.nix {
            defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          })
        ];
      };
    };
}
