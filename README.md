# polaris-streamer-flake

Nix flake packaging for [Polaris](https://github.com/papi-ux/polaris), the self-hosted game streaming host for Moonlight/Nova.

This flake packages Polaris from upstream source and exposes a NixOS module at `services.polaris-stream`.

## NixOS Usage

```nix
{
  inputs.polaris-streamer = {
    url = "github:YOUR_USER/polaris-streamer-flake";
    inputs.nixpkgs.follows = "nixpkgs-unstable";
  };
}
```

Import the module for the host:

```nix
inputs.polaris-streamer.nixosModules.default
```

Example host config:

```nix
services.polaris-stream = {
  enable = true;
  autoStart = true;
  openFirewall = true;

  settings = {
    port = 48989;
    sunshine_name = "nixos-polaris";
    encoder = "vaapi";
    headless_mode = "enabled";
    linux_use_cage_compositor = "enabled";
    linux_prefer_gpu_native_capture = "disabled";
    adaptive_bitrate_enabled = "enabled";
    hdr_mode = 0;
    color_range = 1;
    max_sessions = 2;
  };
};
```

The web UI is served over HTTPS at `https://localhost:<port + 1>`.

With the example above, open:

```text
https://localhost:48990
```
