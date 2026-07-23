{
  description = "Nix flake for Polaris game streaming host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
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
                  package = pkgs.writeShellScriptBin "polaris" "exit 0";
                  settings = {
                    encoder = "vaapi";
                    trusted_subnets = [
                      "10.0.0.0/24"
                      "192.168.0.0/16"
                    ];
                    global_prep_cmd = [
                      {
                        do = "true";
                        undo = "true";
                        elevated = false;
                      }
                    ];
                  };
                  applications.apps = [
                    {
                      name = "Test application";
                      cmd = "true";
                    }
                  ];
                };
              }
            ];
          };
          cfg = moduleEval.config;
          service = cfg.systemd.user.services.polaris-stream.serviceConfig;
          configFileMatch = builtins.match ''.* "(/nix/store/[^"]+-polaris.conf)"'' service.ExecStart;
          configFile = builtins.elemAt configFileMatch 0;
        in
        {
          package = self.packages.${system}.default;
          module = pkgs.runCommand "polaris-stream-module-check" { inherit (service) ExecStart; } ''
            test "${toString cfg.services.polaris-stream.settings.port}" = "47989"
            test "${toString cfg.networking.firewall.allowedTCPPorts}" = "47984 47989 47990 48010"
            test "${
              toString (
                builtins.all (port: builtins.elem port cfg.networking.firewall.allowedUDPPorts) [
                  47998
                  47999
                  48000
                  48010
                ]
              )
            }" = "1"
            test "${toString service.LimitNICE}" = "-10"
            test "${toString service.LimitRTPRIO}" = "95"
            test "${service.ExecStartPre}" = "${pkgs.coreutils}/bin/sleep 5"

            ${pkgs.gnugrep}/bin/grep -F 'trusted_subnets = ["10.0.0.0/24","192.168.0.0/16"]' "${configFile}"
            ${pkgs.gnugrep}/bin/grep -F 'global_prep_cmd = [{"do":"true","elevated":false,"undo":"true"}]' "${configFile}"
            apps_file="$(${pkgs.gnugrep}/bin/grep '^file_apps = ' "${configFile}" | ${pkgs.coreutils}/bin/cut -d ' ' -f 3)"
            ${pkgs.gnugrep}/bin/grep -F '"name": "Test application"' "$apps_file"
            touch $out
          '';
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
            defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          })
        ];
      };
    };
}
