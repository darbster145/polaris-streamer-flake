# polaris-streamer-flake

Nix packaging for [Polaris](https://github.com/papi-ux/polaris), a self-hosted game streaming host for Moonlight and Nova.

The flake builds Polaris from source and provides:

- `packages.<system>.default` and `packages.<system>.polaris-stream`
- `apps.<system>.default` and `apps.<system>.polaris-stream`
- `overlays.default`
- `nixosModules.default`, configured through `services.polaris-stream`

Supported systems are `x86_64-linux` and `aarch64-linux`. The package tracks the
latest stable release, currently **1.4.12**.

## NixOS Usage

Add the input to your flake and make it follow the same nixpkgs revision as the rest of your system:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    polaris-streamer = {
      url = "github:darbster145/polaris-streamer-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Import the module for the host:

```nix
{
  imports = [ inputs.polaris-streamer.nixosModules.default ];
}
```

Then enable Polaris:

```nix
services.polaris-stream = {
  enable = true;
  serviceUser = "alice"; # An existing NixOS account.
  autoStart = true;
  openFirewall = true;

  settings = {
    port = 48989;
    sunshine_name = "nixos-polaris";
    encoder = "vaapi";
    linux_stream_mode = "headless_stream";
    adaptive_bitrate_enabled = "enabled";
    hdr_mode = 0;
    color_range = 1;
    max_sessions = 2;

    # Lists and attribute sets are encoded as JSON values.
    trusted_subnets = [
      "10.0.0.0/24"
      "192.168.0.0/16"
    ];
  };
};
```

The web UI is served over HTTPS at `https://localhost:<port + 1>`. With the example above, open `https://localhost:48990`.

## Declarative Configuration

When `settings` contains anything except the default port, the module generates
a configuration source in the Nix store and copies it to a private, user-owned
runtime directory at every service start. Polaris requires an owned regular
file and an adjacent lock file even when the web UI only reads configuration.
Web UI edits affect the runtime copy and are reset on restart. Manage the
complete configuration through Nix, or leave `settings` at its default and
configure Polaris through the web UI.

Do not place passwords, API keys, tokens, cookies, or other secrets in `settings`. Nix store files are readable by all local users. The module emits a warning for common secret-looking setting names, but that check is not a substitute for keeping secrets out of the store.

Polaris settings that use JSON syntax can be written as normal Nix lists or attribute sets. For example:

```nix
services.polaris-stream.settings.global_prep_cmd = [
  {
    do = "command-to-run";
    undo = "command-to-undo";
    elevated = false;
  }
];
```

For an externally managed configuration, including a file provisioned by a
secrets manager, use a quoted runtime path:

```nix
services.polaris-stream = {
  configFile = "/run/secrets/polaris.conf";
  openFirewall = true;
  settings.port = 48989; # Must match the port in the external file.
};
```

The module reads this source at service startup and copies it into the same
private runtime directory, without putting its contents in the Nix store or
modifying the original. This supports secret-manager symlinks and read-only
source files. The source must resolve to a regular file readable by the service
account. Provision it before startup; web UI edits to the copy are reset on
restart. `configFile` cannot be combined with declarative
`applications` or settings other than `settings.port`. In this mode,
`settings.port` only determines firewall rules; it does not override the file.
With the default value, the file must also use port 47989 when opening stream
ports. Relative paths inside the file still resolve under Polaris's usual
configuration directory, not alongside the external file.

Managed config copies use a directory with mode 0700 and a file with mode 0600
under the user's runtime directory. The directory survives service restarts,
but is removed on a full stop or reboot. Configuration-adjacent portal consent
tokens have the same lifetime, so portal capture may require consent again.
Credentials and pairing state remain in Polaris's normal configuration directory.

## Applications

Applications can also be managed declaratively:

```nix
services.polaris-stream.applications = {
  env.PATH = "$(PATH):$(HOME)/.local/bin";
  apps = [
    {
      name = "Steam Big Picture";
      cmd = "steam -tenfoot";
      image-path = "steam";
    }
  ];
};
```

When either applications or environment variables are declared, the module
generates an immutable `apps.json` and configures Polaris to use it. An
environment-only declaration uses an empty application list; it does not merge
with the web UI's library. This also makes the main configuration declarative.

## DRM/KMS Capture

The default headless Wayland/VAAPI path does not require `CAP_SYS_ADMIN`. Enable the capability wrapper only when using DRM/KMS capture:

```nix
services.polaris-stream.capSysAdmin = true;
```

This is intentionally opt-in because `CAP_SYS_ADMIN` is a broad capability.

## Service Operation

Polaris runs as a systemd user service and starts with the graphical session by
default. Like upstream, it is not stopped when the graphical session target
stops. Its lifetime still depends on the user manager; lingering is needed to
keep it running after the last login session ends. Restarts requested through
the web UI or tray are handled by systemd, including after a package upgrade:

```text
systemctl --user status polaris-stream
journalctl --user -u polaris-stream
systemctl --user restart polaris-stream
```

Set `services.polaris-stream.autoStart = false` to install the service without automatically starting it.

Set `serviceUser` to an existing NixOS account to limit this unit's automatic and
manual startup to that account's user manager. It also grants the required
device groups to that account. Other users can still run the packaged binary
directly. With the default `serviceUser = null`, every user manager can start the
unit; keep only one instance running to avoid port and device conflicts.

For a dedicated host that should start without a desktop login:

```nix
services.polaris-stream = {
  enable = true;
  startAtBoot = true;
  serviceUser = "alice"; # An existing account that will run Polaris.
  settings.linux_stream_mode = "headless_stream";
};
```

`serviceUser` and accounts listed in `users` receive the audio, video, render,
input, and uinput groups used by upstream. With `startAtBoot`, they also receive
lingering. Restart their sessions after changing groups. A working user audio
service is still required.
The `users` list grants permissions and lingering; `serviceUser` controls which
account may start the unit.

For a custom desktop session, `desktopUserTarget` selects the startup target
(default: `graphical-session.target`). `desktopUserReadyTarget` selects the
target Polaris starts after; null uses `desktopUserTarget`. These options match
upstream's names. Ordering does not start a target or require it to be active,
and stopping it does not stop Polaris. `startAtBoot` always uses `default.target`
for automatic startup.

Additional service environment variables can be set with
`services.polaris-stream.environment`. The service inherits the user manager's
PATH unless `environment.PATH` is explicitly set.

Use `extraPackages` to make tools available to Polaris, launched applications,
and preparation commands:

```nix
services.polaris-stream.extraPackages = [ pkgs.mangohud pkgs.gamemode ];
```

Their `bin` directories are prepended to the inherited or explicitly configured
PATH. The package wrapper continues to supply its own runtime tools.

To limit the module's firewall openings to selected interfaces:

```nix
services.polaris-stream = {
  openFirewall = true;
  firewallInterfaces = [ "enp1s0" "tailscale0" ];
};
```

The default empty list opens ports on all interfaces. This applies to both
GameStream and optional Browser Stream rules; it does not change Polaris's bind
address, other firewall rules, or Avahi's separate discovery rules.

## Build Features

The default build includes DRM/KMS, VAAPI, Vulkan Video, Wayland, X11, PipeWire,
portal capture, and the experimental Browser Stream helper. Capture paths still
require the appropriate host drivers and session services.

The web UI and Go helper build separately from the C++ host. CUDA variants can
reuse these outputs. Dynamically loaded graphics libraries use ELF RUNPATH,
without adding a package-wide `LD_LIBRARY_PATH` to launched games. The package
also supplies `xdg-open`, `bwrap`, `pactl`, `xrandr`, and `lspci` for upstream
desktop, input-isolation, and diagnostic features.

### Browser Stream

The helper is built offline from pinned Go dependencies. Enable the feature in
the web UI, or declaratively:

```nix
services.polaris-stream = {
  settings.browser_streaming = true;
  openFirewall = true;
  openBrowserStreamFirewall = true;
};
```

Upstream uses **UDP 47992** for WebTransport even when `settings.port` changes.
The separate firewall option opens this fixed port; it does not enable streaming
by itself. Upstream still labels Browser Stream experimental.

### CUDA capture

CUDA-native capture is optional. It can avoid GPU-to-system-memory copies on
NVIDIA; prepared FFmpeg's NVENC encoding support is a separate feature. The
standalone flake package defaults to CUDA disabled so it does not require unfree
toolkit dependencies. The NixOS module builds with the host's `pkgs`, respecting
`nixpkgs.config.cudaSupport` and package overrides.

To enable CUDA just for Polaris, use the overlay and override:

```nix
nixpkgs.overlays = [ inputs.polaris-streamer.overlays.default ];
nixpkgs.config.allowUnfree = true;
services.polaris-stream.package = pkgs.polaris-stream.override {
  cudaSupport = true;
};
```

The CUDA build uses nixpkgs' compatible compiler and toolkit. NVIDIA host drivers
must be configured separately. To omit Browser Stream, use the same package
override with `enableBrowserStream = false`.

The selected features are exposed as `passthru.buildFeatures`.

### Remaining upstream integrations

- The optional multiseat worker remains disabled, matching the upstream CMake
  default. It is a container entrypoint, not a switch that enables host Spaces.
  Spaces requires additional work: upstream's trusted Docker/runc paths are
  incompatible with normal NixOS paths.
- Upstream's patched Gamescope/HDR compositor, private portal service stack,
  and Home Manager/hjem modules are not integrated here. Shipping the upstream
  session scripts does not provide that complete stack. The labwc path is SDR.

## Overlay

The optional overlay exposes `pkgs.polaris-stream`:

```nix
nixpkgs.overlays = [ inputs.polaris-streamer.overlays.default ];
```

The NixOS module does not require the overlay.

## Development

Run all package and module checks on a supported Linux host with:

```text
nix flake check --print-build-logs
```

Evaluate both architectures without compiling the Linux host with:

```text
nix flake check --all-systems --no-build
```

CI builds on native x86-64 and ARM64 Linux runners. Full flake checks have passed
on both native architectures, with additional ARM emulation checks on x86-64.
Checks include isolated web UI credential creation, a fresh login, and an
authenticated configuration request against the actual Polaris binary.
The optional x86-64 CUDA variant also compiled and passed its install checks.
GPU streaming, NVIDIA driver loading, and KMS still need hardware validation.

Format Nix files with:

```text
nix fmt
```

The package exposes a `passthru.updateScript` based on `nix-update`. A manual equivalent is:

```text
nix run nixpkgs#nix-update -- --flake polaris-stream
```

When updating Polaris, also verify `npmDepsHash` in `nix/web-ui.nix`,
`vendorHash` in `nix/browser-stream-helper.nix`, the prepared FFmpeg version and
both architecture hashes, and the small CMake patch. Build both Linux outputs;
an updated source hash alone does not validate a release upgrade.
