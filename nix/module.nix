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

  settingsValueType = types.nullOr (
    types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      (types.listOf settingsValueType)
      (types.attrsOf settingsValueType)
    ]
  );
  renderSetting =
    value:
    if value == null then
      ""
    else if builtins.isBool value then
      lib.boolToString value
    else if builtins.isInt value then
      toString value
    else if builtins.isFloat value then
      lib.strings.floatToString value
    else if builtins.isList value || builtins.isAttrs value then
      builtins.toJSON value
    else
      value;
  settingsFormat = {
    type = types.attrsOf settingsValueType;
    generate =
      name: value:
      pkgs.writeText name (
        lib.generators.toKeyValue {
          mkKeyValue = key: setting: "${key} = ${renderSetting setting}";
        } value
      );
  };

  appsFile = appsFormat.generate "apps.json" cfg.applications;
  configFile = settingsFormat.generate "polaris.conf" cfg.settings;

  hasCustomConfig =
    cfg.applications.apps != [ ]
    || (builtins.length (builtins.attrNames cfg.settings) > 1 || cfg.settings.port != defaultPort);

  sensitiveSettingNames = builtins.filter (
    name:
    builtins.any (marker: lib.hasInfix marker (lib.toLower name)) [
      "api_key"
      "cookie"
      "credential"
      "passphrase"
      "password"
      "secret"
      "token"
    ]
  ) (builtins.attrNames cfg.settings);
in
{
  imports = [
    (mkAliasOptionModule
      [ "services" "polaris-stream" "enableFirewall" ]
      [ "services" "polaris-stream" "openFirewall" ]
    )
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
        Settings rendered into an immutable Polaris configuration file. When any
        non-default setting is present, the configuration is managed through Nix
        and cannot be persisted through the web UI.

        Lists and attribute sets are rendered as JSON values. Do not put secrets
        here because generated Nix store files are readable by all local users.
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
          type = types.addCheck port (value: value >= 6 && value <= 65514);
          default = defaultPort;
          description = ''
            Base port. Polaris derives related ports from this value:
            GameStream HTTPS is port - 5, HTTP is port, web UI HTTPS is port + 1,
            stream UDP ports are port + 9 through port + 11, and RTSP is port + 21.
            Therefore, the base port must be between 6 and 65514.
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
    warnings = optionals (sensitiveSettingNames != [ ]) [
      ''
        services.polaris-stream.settings contains secret-looking keys:
        ${builtins.concatStringsSep ", " sensitiveSettingNames}. Values declared
        here are stored in the world-readable Nix store. Configure secrets through
        the Polaris web UI or another runtime-only mechanism instead.
      ''
    ];

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
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        ExecStart = escapeSystemdExecArgs (
          [
            (
              if cfg.capSysAdmin then "${config.security.wrapperDir}/polaris-stream" else "${getExe cfg.package}"
            )
          ]
          ++ optionals hasCustomConfig [ "${configFile}" ]
        );
        LimitNICE = -10;
        LimitRTPRIO = 95;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
