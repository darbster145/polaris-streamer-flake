# polaris-streamer-flake

Nix packaging for [Polaris](https://github.com/papi-ux/polaris), a self-hosted game streaming host for Moonlight and Nova.

The flake builds Polaris from source and provides:

- `packages.x86_64-linux.default`
- `apps.x86_64-linux.default`
- `overlays.default`
- `nixosModules.default`, configured through `services.polaris-stream`

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

When `settings` contains anything except the default port, the module generates an immutable `polaris.conf` in the Nix store. The web UI can read those settings but cannot persist changes to that file. Manage the complete configuration through Nix, or leave `settings` at its default and configure Polaris through the web UI.

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

When at least one application is declared, the module generates `apps.json` and configures Polaris to use it.

## DRM/KMS Capture

The default headless Wayland/VAAPI path does not require `CAP_SYS_ADMIN`. Enable the capability wrapper only when using DRM/KMS capture:

```nix
services.polaris-stream.capSysAdmin = true;
```

This is intentionally opt-in because `CAP_SYS_ADMIN` is a broad capability.

## Service Operation

Polaris runs as a systemd user service tied to the graphical session:

```text
systemctl --user status polaris-stream
journalctl --user -u polaris-stream
systemctl --user restart polaris-stream
```

Set `services.polaris-stream.autoStart = false` to install the service without automatically starting it.

## Build Features

The packaged build supports DRM/KMS, VAAPI, Vulkan Video, Wayland, X11, PipeWire, and portal capture. The following upstream features are disabled in the current package:

- CUDA-native capture is disabled. NVIDIA encoding available through the prepared FFmpeg build is separate from Polaris's CUDA-native capture path.
- Experimental Browser Stream support is disabled because its Go dependencies are not yet packaged for an offline Nix build.
- The optional multiseat worker is not built. Spaces host integration is not configured by this module.

These exclusions are exposed as `passthru.buildFeatures` on the package so downstream automation can inspect them.

Only `x86_64-linux` is currently exposed because the prepared FFmpeg dependency is architecture-specific.

## Overlay

The optional overlay exposes `pkgs.polaris-stream`:

```nix
nixpkgs.overlays = [ inputs.polaris-streamer.overlays.default ];
```

The NixOS module does not require the overlay.

## Development

Run all package and module checks with:

```text
nix flake check --print-build-logs
```

Format Nix files with:

```text
nix fmt
```

The package exposes a `passthru.updateScript` based on `nix-update`. A manual equivalent is:

```text
nix run nixpkgs#nix-update -- --flake polaris-stream
```
