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
  generatedConfigFile = settingsFormat.generate "polaris.conf" cfg.settings;
  hasApplications = cfg.applications.apps != [ ] || cfg.applications.env != { };

  hasCustomConfig =
    hasApplications
    || (builtins.length (builtins.attrNames cfg.settings) > 1 || cfg.settings.port != defaultPort);

  serviceUsers = lib.unique (cfg.users ++ lib.optional (cfg.serviceUser != null) cfg.serviceUser);
  readyTarget =
    if cfg.desktopUserReadyTarget != null then cfg.desktopUserReadyTarget else cfg.desktopUserTarget;
  serviceCommand = [
    (if cfg.capSysAdmin then "${config.security.wrapperDir}/polaris-stream" else getExe cfg.package)
  ]
  ++ (
    if cfg.configFile != null then
      [ cfg.configFile ]
    else
      optionals hasCustomConfig [ "${generatedConfigFile}" ]
  );
  # Expand the inherited PATH at runtime, which systemd's Environment= cannot do.
  serviceLauncher = pkgs.writeShellScript "polaris-stream-launch" ''
    export PATH=${lib.escapeShellArg (lib.makeBinPath cfg.extraPackages)}"''${PATH:+:$PATH}"
    exec ${lib.escapeShellArgs serviceCommand}
  '';
  firewallPorts = {
    allowedTCPPorts = optionals cfg.openFirewall (
      generatePorts cfg.settings.port [
        (-5)
        0
        1
        21
      ]
    );
    allowedUDPPorts =
      optionals cfg.openFirewall (
        generatePorts cfg.settings.port [
          9
          10
          11
          21
        ]
      )
      ++ optionals cfg.openBrowserStreamFirewall [ 47992 ];
  };

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
      defaultText = literalExpression ''pkgs.callPackage (inputs.polaris-streamer + "/nix/package.nix") { }'';
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

    openBrowserStreamFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Open UDP port 47992 for the optional Browser Stream WebTransport helper.
        Upstream uses this fixed port independently of settings.port. Enable
        Browser Stream separately in Polaris; opening the port does not enable it.
      '';
    };

    firewallInterfaces = mkOption {
      type = listOf str;
      default = [ ];
      example = [
        "enp1s0"
        "tailscale0"
      ];
      description = ''
        Interfaces on which openFirewall and openBrowserStreamFirewall open
        Polaris ports. An empty list opens them on all interfaces. This does not
        restrict existing firewall rules, Avahi discovery, or Polaris's bind address.
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

    startAtBoot = mkOption {
      type = bool;
      default = false;
      description = ''
        Start Polaris with the user manager instead of waiting for a graphical
        session. Requires autoStart. The serviceUser and users listed in `users`
        have lingering enabled so their user managers start at boot. Configure a
        private stream mode and a working user audio service for streaming
        without a desktop.
      '';
    };

    serviceUser = mkOption {
      type = nullOr (strMatching "[a-zA-Z_][a-zA-Z0-9_-]*[$]?");
      default = null;
      example = "alice";
      description = ''
        Existing NixOS account whose user manager may start the Polaris unit.
        Uses systemd ConditionUser, including for manual starts. This account
        also receives device groups and, with startAtBoot, lingering. Null keeps
        the global user unit available to every account. This scopes the service;
        it does not prevent other users from running the Polaris binary directly.
      '';
    };

    desktopUserTarget = mkOption {
      type = str;
      default = "graphical-session.target";
      example = "plasma-workspace.target";
      description = ''
        User target that starts Polaris when autoStart is enabled. startAtBoot
        instead uses default.target. Stopping this target does not stop Polaris.
      '';
    };

    desktopUserReadyTarget = mkOption {
      type = nullOr str;
      default = null;
      example = "graphical-session-pre.target";
      description = ''
        Target ordered before Polaris starts. Null uses desktopUserTarget.
        This adds After ordering only and does not pull the target into a
        headless user manager or require it to be active.
      '';
    };

    users = mkOption {
      type = listOf str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Existing users granted access to audio, video, render, input, and uinput
        devices, matching upstream's NixOS module. Input access is needed for
        isolated virtual devices and device groups support sessions without
        active-seat ACLs. When startAtBoot is enabled, also enable lingering for
        these users. Restart their user sessions after changing group membership.
      '';
    };

    environment = mkOption {
      type = attrsOf str;
      default = { };
      description = ''
        Additional environment variables for the Polaris user service and its
        child processes. Values are stored in the world-readable Nix store.
      '';
    };

    extraPackages = mkOption {
      type = listOf package;
      default = [ ];
      example = literalExpression "[ pkgs.mangohud pkgs.gamemode ]";
      description = ''
        Packages added to PATH for Polaris and its launched applications and
        preparation commands. Their bin directories are prepended to the user
        manager's inherited PATH, or to environment.PATH when explicitly set.
        The Polaris package's own runtime tools are still supplied by its wrapper.
      '';
    };

    configFile = mkOption {
      type = nullOr (
        addCheck str (value: lib.hasPrefix "/" value && !lib.hasInfix "\n" value && !lib.hasInfix "=" value)
      );
      default = null;
      example = "/run/secrets/polaris.conf";
      description = ''
        Absolute path to an externally managed Polaris configuration, read at
        runtime without copying its contents into the Nix store. Use a quoted
        string, not a Nix path literal. The file must exist and be readable by
        the service account before startup; web UI edits also require it to be
        writable. Paths containing newlines or '=' are unsupported by the
        module or upstream's command-line parser. Cannot be combined with
        applications or settings other than settings.port. When used here,
        settings.port only determines generated firewall rules and must match
        the external file's base port.
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
          linux_stream_mode = "headless_stream";
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
            With configFile, this only determines firewall rules; keep it in
            sync with the port in that external file.
          '';
        };
      };
    };

    applications = mkOption {
      default = { };
      description = ''
        Applications to expose to Moonlight/Nova. If this is set, the generated
        applications file is referenced from `settings.file_apps`. Setting only
        `env` also generates this file, with the declared (possibly empty) apps
        list. The web UI cannot persist changes to this immutable file.
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
    assertions = [
      {
        assertion = !cfg.startAtBoot || cfg.autoStart;
        message = "services.polaris-stream.startAtBoot requires autoStart to be enabled.";
      }
      {
        assertion =
          cfg.configFile == null || (!hasApplications && builtins.removeAttrs cfg.settings [ "port" ] == { });
        message = "services.polaris-stream.configFile cannot be combined with applications or settings other than settings.port (used for firewall rules).";
      }
    ];

    warnings = optionals (sensitiveSettingNames != [ ]) [
      ''
        services.polaris-stream.settings contains secret-looking keys:
        ${builtins.concatStringsSep ", " sensitiveSettingNames}. Values declared
        here are stored in the world-readable Nix store. Configure secrets through
        the Polaris web UI or another runtime-only mechanism instead.
      ''
    ];

    services.polaris-stream.settings.file_apps = mkIf hasApplications "${appsFile}";

    environment.systemPackages = [ cfg.package ];

    networking.firewall = mkIf (cfg.openFirewall || cfg.openBrowserStreamFirewall) (
      if cfg.firewallInterfaces == [ ] then
        firewallPorts
      else
        { interfaces = lib.genAttrs cfg.firewallInterfaces (_: firewallPorts); }
    );

    hardware.uinput.enable = true;
    boot.kernelModules = [ "uhid" ];

    services.udev.packages = [ cfg.package ];

    users.users = lib.genAttrs serviceUsers (_user: {
      extraGroups = [
        "audio"
        "uinput"
        "video"
        "render"
        "input"
      ];
      linger = mkIf cfg.startAtBoot true;
    });

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

      wantedBy = mkIf cfg.autoStart [
        (if cfg.startAtBoot then "default.target" else cfg.desktopUserTarget)
      ];
      # Match the upstream service: private streams must survive desktop logout,
      # and a headless user manager must not pull in the graphical session.
      after = [ readyTarget ];

      unitConfig.ConditionUser = mkIf (cfg.serviceUser != null) cfg.serviceUser;

      startLimitIntervalSec = 500;
      startLimitBurst = 5;

      environment = cfg.environment // {
        PATH = lib.mkForce (cfg.environment.PATH or null);
        # Upstream auto-detects only polaris.service; our unit has a distinct name.
        POLARIS_SERVICE_RESTART = "1";
      };

      serviceConfig = {
        ExecStartPre =
          if cfg.configFile == null then
            "${pkgs.coreutils}/bin/sleep 5"
          else
            [ "${pkgs.coreutils}/bin/sleep 5" ]
            ++
              map
                (
                  flag:
                  escapeSystemdExecArgs [
                    "${pkgs.coreutils}/bin/test"
                    flag
                    cfg.configFile
                  ]
                )
                [
                  "-f"
                  "-r"
                ];
        ExecStart = escapeSystemdExecArgs (
          if cfg.extraPackages == [ ] then serviceCommand else [ "${serviceLauncher}" ]
        );
        LimitNICE = -10;
        LimitRTPRIO = 95;
        Restart = "on-failure";
        RestartSec = "5s";
        SuccessExitStatus = [ 75 ];
        RestartForceExitStatus = [ 75 ];
      };
    };
  };
}
