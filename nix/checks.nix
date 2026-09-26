{
  self,
  nixpkgs,
  system,
  pkgs,
}:
let
  inherit (nixpkgs) lib;
  stubPackage = pkgs.writeShellScriptBin "polaris" ''
    ${lib.getExe pkgs.jq} -cn \
      --arg path "$PATH" \
      --arg marker "''${POLARIS_TEST_MARKER:-}" \
      --arg helper "$(command -v polaris-test-helper || true)" \
      --args '{path: $path, marker: $marker, helper: $helper, args: $ARGS.positional}' "$@"
  '';
  extraPackage = pkgs.writeShellScriptBin "polaris-test-helper" "exit 0";
  eval =
    module:
    (lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          system.stateVersion = "25.11";
          services.polaris-stream = {
            enable = true;
            package = stubPackage;
          };
        }
        module
      ];
    }).config;
  defaults = eval { };
  defaultUnit = defaults.systemd.user.services.polaris-stream;
  configured = eval {
    services.polaris-stream = {
      openFirewall = true;
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
  };
  portConfig =
    port:
    eval {
      services.polaris-stream = {
        openFirewall = true;
        settings.port = port;
      };
    };
  changedPort = portConfig 48989;
  browserFirewall = eval {
    services.polaris-stream = {
      openBrowserStreamFirewall = true;
      settings.port = 48989;
    };
  };
  envOnly = eval {
    services.polaris-stream.applications.env.TEST = "environment only";
  };
  boot = eval {
    users.users.alice.isNormalUser = true;
    services.polaris-stream = {
      startAtBoot = true;
      users = [ "alice" ];
      environment = {
        TEST = "service environment";
        PATH = "/custom/bin";
      };
    };
  };
  noAutoStart = eval { services.polaris-stream.autoStart = false; };
  invalidBoot = eval {
    services.polaris-stream = {
      autoStart = false;
      startAtBoot = true;
    };
  };
  kms = eval { services.polaris-stream.capSysAdmin = true; };
  selectedUser = eval {
    users.users.alice.isNormalUser = true;
    users.users.bob.isNormalUser = true;
    services.polaris-stream = {
      serviceUser = "alice";
      users = [ "bob" ];
      startAtBoot = true;
    };
  };
  runtimeConfig = eval {
    services.polaris-stream = {
      configFile = "/run/secrets/polaris.conf";
      settings.port = 48989;
      openFirewall = true;
    };
  };
  conflictingRuntimeSettings = eval {
    services.polaris-stream = {
      configFile = "/run/secrets/polaris.conf";
      settings.encoder = "vaapi";
    };
  };
  conflictingRuntimeApps = eval {
    services.polaris-stream = {
      configFile = "/run/secrets/polaris.conf";
      applications.env.TEST = "must not be discarded";
    };
  };
  extraPackages = eval {
    services.polaris-stream.extraPackages = [ extraPackage ];
  };
  extraPackagesConfig = eval {
    services.polaris-stream = {
      extraPackages = [ extraPackage ];
      environment.PATH = "/configured/bin";
      configFile = "/run/secrets/polaris $cash%quoted' config.conf";
    };
  };
  extraPackagesKms = eval {
    services.polaris-stream = {
      extraPackages = [ extraPackage ];
      capSysAdmin = true;
    };
  };
  interfaceFirewall = eval {
    services.polaris-stream = {
      openFirewall = true;
      openBrowserStreamFirewall = true;
      settings.port = 48989;
      firewallInterfaces = [
        "wg0"
        "tailscale0"
      ];
    };
  };
  customTarget = eval {
    services.polaris-stream.desktopUserTarget = "my-session.target";
  };
  customReadyTarget = eval {
    services.polaris-stream = {
      desktopUserTarget = "my-session.target";
      desktopUserReadyTarget = "my-ready.target";
    };
  };
  hostConfiguredPackage =
    (lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        { nixpkgs.config.cudaSupport = true; }
      ];
    }).config.services.polaris-stream.package;
  getConfigFile =
    config:
    let
      command = config.systemd.user.services.polaris-stream.serviceConfig.ExecStart;
      path = builtins.elemAt (builtins.match ''.* "(/nix/store/[^"]+-polaris.conf)"'' command) 0;
    in
    # Regex captures lose Nix string context. Retain the config's build dependency.
    builtins.appendContext path (builtins.getContext command);
  getLauncher =
    config:
    let
      command = config.systemd.user.services.polaris-stream.serviceConfig.ExecStart;
      path = builtins.elemAt (builtins.match ''"([^"]+)"'' command) 0;
    in
    builtins.appendContext path (builtins.getContext command);
  polarisFailedAssertions =
    config:
    builtins.filter (
      entry: !entry.assertion && lib.hasPrefix "services.polaris-stream." entry.message
    ) config.assertions;
  includesAll = actual: expected: builtins.all (port: builtins.elem port actual) expected;
  rejectsPort =
    port:
    !(builtins.tryEval (builtins.deepSeq (portConfig port).services.polaris-stream.settings.port true))
    .success;
  rejectsConfigFile =
    path:
    !(builtins.tryEval (
      builtins.deepSeq
        (eval { services.polaris-stream.configFile = path; }).services.polaris-stream.configFile
        true
    )).success;
  moduleAssertions = [
    {
      condition = hostConfiguredPackage.buildFeatures.cudaCapture;
      message = "The module's default package must honor the host nixpkgs CUDA configuration.";
    }
    {
      condition = defaultUnit.serviceConfig.ExecStart == "\"${lib.getExe stubPackage}\"";
      message = "Default settings must keep upstream's writable configuration path.";
    }
    {
      condition = !builtins.hasAttr "file_apps" defaults.services.polaris-stream.settings;
      message = "Default applications must keep upstream's writable apps.json.";
    }
    {
      condition =
        defaults.networking.firewall.allowedTCPPorts == [ ]
        && !(builtins.elem 47998 defaults.networking.firewall.allowedUDPPorts);
      message = "Polaris stream ports must stay closed unless openFirewall is enabled.";
    }
    {
      condition =
        configured.networking.firewall.allowedTCPPorts == [
          47984
          47989
          47990
          48010
        ]
        && includesAll configured.networking.firewall.allowedUDPPorts [
          47998
          47999
          48000
          48010
        ];
      message = "Default firewall rules must match the upstream GameStream ports.";
    }
    {
      condition =
        changedPort.networking.firewall.allowedTCPPorts == [
          48984
          48989
          48990
          49010
        ]
        && includesAll changedPort.networking.firewall.allowedUDPPorts [
          48998
          48999
          49000
          49010
        ];
      message = "Custom base ports must shift all GameStream firewall rules.";
    }
    {
      condition =
        builtins.elem 47992 browserFirewall.networking.firewall.allowedUDPPorts
        && !(builtins.elem 48992 browserFirewall.networking.firewall.allowedUDPPorts)
        && browserFirewall.networking.firewall.allowedTCPPorts == [ ]
        && !(builtins.elem 47992 configured.networking.firewall.allowedUDPPorts);
      message = "Browser Stream must open only its fixed, independently opted-in UDP port.";
    }
    {
      condition =
        (portConfig 6).networking.firewall.allowedTCPPorts == [
          1
          6
          7
          27
        ]
        && builtins.elem 65535 (portConfig 65514).networking.firewall.allowedTCPPorts
        && rejectsPort 5
        && rejectsPort 65515;
      message = "Base port bounds must keep every derived port within 1..65535.";
    }
    {
      condition =
        defaultUnit.environment.POLARIS_SERVICE_RESTART == "1"
        && defaultUnit.serviceConfig.SuccessExitStatus == [ 75 ]
        && defaultUnit.serviceConfig.RestartForceExitStatus == [ 75 ]
        && defaultUnit.serviceConfig.Restart == "on-failure";
      message = "UI/tray restart must use systemd even with the polaris-stream unit name.";
    }
    {
      condition =
        defaultUnit.wantedBy == [ "graphical-session.target" ]
        && defaultUnit.partOf == [ ]
        && defaultUnit.wants == [ ]
        && defaultUnit.environment.PATH == null
        && noAutoStart.systemd.user.services.polaris-stream.wantedBy == [ ];
      message = "Private streams must survive desktop target stop, with opt-in autostart.";
    }
    {
      condition =
        defaultUnit.serviceConfig.LimitNICE == -10
        && defaultUnit.serviceConfig.LimitRTPRIO == 95
        && defaultUnit.serviceConfig.ExecStartPre == "${pkgs.coreutils}/bin/sleep 5"
        && builtins.elem stubPackage defaults.services.udev.packages
        && defaults.hardware.uinput.enable
        && builtins.elem "uhid" defaults.boot.kernelModules;
      message = "Upstream worker limits and virtual-input device setup must remain installed.";
    }
    {
      condition =
        boot.systemd.user.services.polaris-stream.wantedBy == [ "default.target" ]
        && boot.users.users.alice.linger
        && includesAll boot.users.users.alice.extraGroups [
          "audio"
          "uinput"
          "video"
          "render"
          "input"
        ]
        && boot.systemd.user.services.polaris-stream.environment.TEST == "service environment"
        && boot.systemd.user.services.polaris-stream.environment.PATH == "/custom/bin"
        && builtins.any (
          entry:
          !entry.assertion
          && entry.message == "services.polaris-stream.startAtBoot requires autoStart to be enabled."
        ) invalidBoot.assertions;
      message = "Headless startup must enable lingering/device groups and reject disabled autostart.";
    }
    {
      condition =
        !builtins.hasAttr "polaris-stream" defaults.security.wrappers
        && kms.security.wrappers.polaris-stream.capabilities == "cap_sys_admin+p"
        && kms.security.wrappers.polaris-stream.source == lib.getExe stubPackage
        &&
          kms.systemd.user.services.polaris-stream.serviceConfig.ExecStart
          == "\"${kms.security.wrapperDir}/polaris-stream\"";
      message = "CAP_SYS_ADMIN must remain opt-in and the service must use its wrapper when enabled.";
    }
    {
      condition =
        !(defaultUnit.unitConfig ? ConditionUser)
        && selectedUser.systemd.user.services.polaris-stream.unitConfig.ConditionUser == "alice"
        &&
          builtins.all
            (
              user:
              selectedUser.users.users.${user}.linger
              && includesAll selectedUser.users.users.${user}.extraGroups [
                "audio"
                "uinput"
                "video"
                "render"
                "input"
              ]
            )
            [
              "alice"
              "bob"
            ];
      message = "serviceUser must restrict the unit and receive device access/lingering alongside explicit users.";
    }
    {
      condition =
        runtimeConfig.systemd.user.services.polaris-stream.serviceConfig.ExecStart
        == "\"${lib.getExe stubPackage}\" \"/run/secrets/polaris.conf\""
        &&
          runtimeConfig.systemd.user.services.polaris-stream.serviceConfig.ExecStartPre == [
            "${pkgs.coreutils}/bin/sleep 5"
            "\"${pkgs.coreutils}/bin/test\" \"-f\" \"/run/secrets/polaris.conf\""
            "\"${pkgs.coreutils}/bin/test\" \"-r\" \"/run/secrets/polaris.conf\""
          ]
        &&
          runtimeConfig.networking.firewall.allowedTCPPorts == [
            48984
            48989
            48990
            49010
          ]
        && polarisFailedAssertions runtimeConfig == [ ]
        && polarisFailedAssertions conflictingRuntimeSettings != [ ]
        && polarisFailedAssertions conflictingRuntimeApps != [ ];
      message = "Runtime configuration must bypass the store file, accept firewall port metadata and reject declarative conflicts.";
    }
    {
      condition =
        rejectsConfigFile "relative.conf"
        && rejectsConfigFile "/run/polaris=alternate.conf"
        && rejectsConfigFile "/run/polaris\n.conf";
      message = "Runtime config paths must be absolute and must not be parsed as CLI assignments or split into commands.";
    }
    {
      condition =
        extraPackages.systemd.user.services.polaris-stream.environment.PATH == null
        && extraPackagesConfig.systemd.user.services.polaris-stream.environment.PATH == "/configured/bin";
      message = "Extra packages must preserve inherited PATH and explicit service environment overrides.";
    }
    {
      condition =
        interfaceFirewall.networking.firewall.allowedTCPPorts == [ ]
        && !(builtins.elem 48998 interfaceFirewall.networking.firewall.allowedUDPPorts)
        && !(builtins.elem 47992 interfaceFirewall.networking.firewall.allowedUDPPorts)
        &&
          builtins.all
            (
              interface:
              interfaceFirewall.networking.firewall.interfaces.${interface}.allowedTCPPorts == [
                48984
                48989
                48990
                49010
              ]
              && includesAll interfaceFirewall.networking.firewall.interfaces.${interface}.allowedUDPPorts [
                47992
                48998
                48999
                49000
                49010
              ]
            )
            [
              "wg0"
              "tailscale0"
            ];
      message = "Interface firewall rules must include shifted stream/fixed Browser ports without globally opening them.";
    }
    {
      condition =
        customTarget.systemd.user.services.polaris-stream.wantedBy == [ "my-session.target" ]
        && customTarget.systemd.user.services.polaris-stream.after == [ "my-session.target" ]
        && customReadyTarget.systemd.user.services.polaris-stream.wantedBy == [ "my-session.target" ]
        && customReadyTarget.systemd.user.services.polaris-stream.after == [ "my-ready.target" ]
        && customReadyTarget.systemd.user.services.polaris-stream.partOf == [ ]
        && customReadyTarget.systemd.user.services.polaris-stream.wants == [ ];
      message = "Custom desktop and readiness targets must control startup ordering without coupling stream lifetime.";
    }
  ];
in
{
  package = self.packages.${system}.default;
  module =
    assert lib.all (entry: lib.assertMsg entry.condition entry.message) moduleAssertions;
    pkgs.runCommand "polaris-stream-module-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
      grep -Fx 'trusted_subnets = ["10.0.0.0/24","192.168.0.0/16"]' "${getConfigFile configured}"
      grep -Fx 'global_prep_cmd = [{"do":"true","elevated":false,"undo":"true"}]' "${getConfigFile configured}"
      jq -e '.apps[0].name == "Test application" and .apps[0].cmd == "true"' \
        "${configured.services.polaris-stream.settings.file_apps}"
      grep -Fx 'port = 48989' "${getConfigFile changedPort}"
      grep -Fx 'file_apps = ${envOnly.services.polaris-stream.settings.file_apps}' "${getConfigFile envOnly}"
      jq -e '.env.TEST == "environment only" and .apps == []' \
        "${envOnly.services.polaris-stream.settings.file_apps}"

      PATH="/inherited path/bin" POLARIS_TEST_MARKER="inherited" \
        "${getLauncher extraPackages}" > inherited.json
      jq -e --arg prefix "${lib.makeBinPath [ extraPackage ]}:" \
        --arg helper "${lib.getExe extraPackage}" \
        '.path == ($prefix + "/inherited path/bin") and .marker == "inherited" and .helper == $helper and .args == []' \
        inherited.json

      PATH="" "${getLauncher extraPackages}" > empty-path.json
      jq -e --arg path "${lib.makeBinPath [ extraPackage ]}" \
        '.path == $path and .args == []' empty-path.json

      PATH="${extraPackagesConfig.systemd.user.services.polaris-stream.environment.PATH}" \
        POLARIS_TEST_MARKER="configured" "${getLauncher extraPackagesConfig}" > configured.json
      jq -e --arg prefix "${lib.makeBinPath [ extraPackage ]}:" \
        --arg config ${lib.escapeShellArg extraPackagesConfig.services.polaris-stream.configFile} \
        '.path == ($prefix + "/configured/bin") and .marker == "configured" and .args == [$config]' \
        configured.json
      grep -F '${extraPackagesKms.security.wrapperDir}/polaris-stream' "${getLauncher extraPackagesKms}"
      touch "$out"
    '';
}
