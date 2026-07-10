{ defaultPackage }:

{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    getExe
    literalExpression
    mkAliasOptionModule
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    optionals
    types
    ;
  inherit (utils) escapeSystemdExecArgs;

  cfg = config.services.polaris-stream;

  defaultPort = 47989;
  generatePorts = port: offsets: map (offset: port + offset) offsets;

  appsFormat = pkgs.formats.json { };
  settingsFormat = pkgs.formats.keyValue { };

  appsFile = appsFormat.generate "apps.json" cfg.applications;
  configFile = settingsFormat.generate "polaris.conf" cfg.settings;

  hasCustomConfig =
    cfg.applications.apps != [ ]
    || (builtins.length (builtins.attrNames cfg.settings) > 1 || cfg.settings.port != defaultPort);
in
{
  imports = [
    (mkAliasOptionModule [ "services" "polaris-stream" "enableFirewall" ] [ "services" "polaris-stream" "openFirewall" ])
  ];

  options.services.polaris-stream = with types; {
    enable = mkEnableOption "Polaris, a self-hosted game stream host for Moonlight";

    package = mkOption {
      type = package;
      default = defaultPackage;
      defaultText = literalExpression "inputs.polaris-streamer.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = ''
        Polaris package to use.
      '';
    };

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to automatically open Polaris ports in the firewall.
      '';
    };

    capSysAdmin = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to give the Polaris binary CAP_SYS_ADMIN, required for DRM/KMS capture.
        This is not needed for the default labwc/Wayland/VAAPI path.
      '';
    };

    autoStart = mkOption {
      type = bool;
      default = true;
      description = ''
        Whether Polaris should be started automatically as a user service.
      '';
    };

    settings = mkOption {
      default = { };
      description = ''
        Settings rendered into the Polaris configuration file. If this is set,
        matching settings should be managed through Nix rather than the web UI.
      '';
      example = literalExpression ''
        {
          sunshine_name = "nixos";
          encoder = "vaapi";
          headless_mode = "enabled";
          linux_use_cage_compositor = "enabled";
          linux_prefer_gpu_native_capture = "disabled";
        }
      '';
      type = submodule {
        freeformType = settingsFormat.type;
        options.port = mkOption {
          type = port;
          default = defaultPort;
          description = ''
            Base port. Polaris derives related ports from this value:
            GameStream HTTPS is port - 5, HTTP is port, web UI HTTPS is port + 1,
            stream UDP ports are port + 9 through port + 11, and RTSP is port + 21.
          '';
        };
      };
    };

    applications = mkOption {
      default = { };
      description = ''
        Applications to expose to Moonlight/Nova. If this is set, the generated
        applications file is referenced from `settings.file_apps`.
      '';
      example = literalExpression ''
        {
          env = {
            PATH = "$(PATH):$(HOME)/.local/bin";
          };
          apps = [
            {
              name = "Steam Big Picture";
              cmd = "steam -tenfoot";
              image-path = "steam";
            }
          ];
        }
      '';
      type = submodule {
        options = {
          env = mkOption {
            default = { };
            description = ''
              Environment variables to set for launched applications.
            '';
            type = attrsOf str;
          };

          apps = mkOption {
            default = [ ];
            description = ''
              Applications to expose to clients.
            '';
            type = listOf attrs;
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services.polaris-stream.settings.file_apps = mkIf (cfg.applications.apps != [ ]) "${appsFile}";

    environment.systemPackages = [ cfg.package ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = generatePorts cfg.settings.port [
        (-5)
        0
        1
        21
      ];
      allowedUDPPorts = generatePorts cfg.settings.port [
        9
        10
        11
        21
      ];
    };

    hardware.uinput.enable = true;
    boot.kernelModules = [ "uhid" ];

    services.udev.extraRules = ''
      # Allows Polaris to access /dev/uinput
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660", TAG+="uaccess"

      # Allows Polaris to access /dev/uhid
      KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"

      # Polaris virtual joypads
      KERNEL=="hidraw*", ATTRS{name}=="Polaris PS5 (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Polaris X-Box One (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Polaris gamepad (virtual) motion sensors", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Polaris Nintendo (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    services.avahi = {
      enable = mkDefault true;
      publish = {
        enable = mkDefault true;
        userServices = mkDefault true;
      };
    };

    security.wrappers.polaris-stream = mkIf cfg.capSysAdmin {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+p";
      source = getExe cfg.package;
    };

    systemd.user.services.polaris-stream = {
      description = "Self-hosted game stream host for Moonlight";

      wantedBy = mkIf cfg.autoStart [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];

      startLimitIntervalSec = 500;
      startLimitBurst = 5;

      environment.PATH = lib.mkForce null;

      serviceConfig = {
        ExecStart = escapeSystemdExecArgs (
          [
            (if cfg.capSysAdmin then "${config.security.wrapperDir}/polaris-stream" else "${getExe cfg.package}")
          ]
          ++ optionals hasCustomConfig [ "${configFile}" ]
        );
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
