{
  stdenv,
  lib,
  fetchFromGitHub,
  fetchzip,
  cmake,
  ninja,
  pkg-config,
  nodejs,
  importNpmLock,
  makeWrapper,
  nix-update-script,
  boost,
  openssl,
  curl,
  libevdev,
  libdrm,
  libcap,
  pipewire,
  wayland,
  wayland-protocols,
  wayland-scanner,
  shaderc,
  vulkan-headers,
  vulkan-loader,
  libva,
  libpulseaudio,
  opus,
  miniupnpc,
  nlohmann_json,
  libxkbcommon,
  libnotify,
  libayatana-appindicator,
  gtk3,
  glib,
  mesa,
  libgbm,
  avahi,
  libglvnd,
  numactl,
  libx11,
  libxrandr,
  libxfixes,
  libxi,
  libxcb,
  libxtst,
  xdpyinfo,
  xwayland,
  grim,
  labwc,
  wlr-randr,
  which,
}:

let
  preparedFfmpeg = fetchzip {
    url = "https://github.com/LizardByte/build-deps/releases/download/v2026.724.203728/Linux-x86_64-ffmpeg.tar.gz";
    hash = "sha256-ERw553AsQ0s/7oEXCiwjJjZEp1hpe9aCgiEBRs0K0R0=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "polaris-stream";
  version = "1.4.4";

  strictDeps = true;

  src = fetchFromGitHub {
    owner = "papi-ux";
    repo = "polaris";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-yZ4B5VhUd8kec4rV6VCBg+BSonqkDjqbMJ7H7uL++Wc=";
  };

  npmDeps = importNpmLock.buildNodeModules {
    npmRoot = finalAttrs.src;
    nodejs = nodejs;
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    nodejs
    importNpmLock.hooks.linkNodeModulesHook
    makeWrapper
    wayland-scanner
    shaderc
  ];

  buildInputs = [
    boost
    openssl
    curl
    libevdev
    libdrm
    libcap
    pipewire
    wayland
    wayland-protocols
    libva
    libpulseaudio
    opus
    miniupnpc
    nlohmann_json
    libxkbcommon
    libnotify
    libayatana-appindicator
    gtk3
    glib
    mesa
    libgbm
    avahi
    libglvnd
    numactl
    libx11
    libxrandr
    libxfixes
    libxi
    libxcb
    libxtst
    vulkan-headers
    vulkan-loader
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-GNinja"
    "-DPOLARIS_ENABLE_CUDA=OFF"
    "-DCUDA_FAIL_ON_MISSING=OFF"
    "-DPOLARIS_ALLOW_CUDA_DISABLED_ON_NVIDIA=ON"
    "-DPOLARIS_ENABLE_BROWSER_STREAM=OFF"
    "-DPOLARIS_SYSTEM_WAYLAND_PROTOCOLS=ON"
    "-DPOLARIS_DOWNLOAD_PREPARED_FFMPEG=OFF"
    "-DFFMPEG_PREPARED_BINARIES=${preparedFfmpeg}"
    "-DBOOST_USE_STATIC=OFF"
    "-DNPM_OFFLINE=ON"
  ];

  postPatch = ''
    substituteInPlace cmake/targets/common.cmake \
      --replace-fail 'COMMAND "$<$<BOOL:''${WIN32}>:cmd;/C>" "''${NPM}" ci --no-audit --fund=false ''${NPM_INSTALL_FLAGS}' 'COMMAND "''${CMAKE_COMMAND}" -E true'
  '';

  postInstall = ''
    wrapProgram $out/bin/polaris \
      --prefix PATH : ${
        lib.makeBinPath [
          grim
          labwc
          wlr-randr
          which
          xdpyinfo
          xwayland
        ]
      } \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          avahi
          libglvnd
          mesa
        ]
      }
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/polaris --version
    runHook postInstallCheck
  '';

  passthru = {
    updateScript = nix-update-script {
      extraArgs = [ "--flake" ];
    };
    buildFeatures = {
      browserStream = false;
      cudaCapture = false;
    };
  };

  meta = {
    description = "Self-hosted game stream host for Moonlight";
    homepage = "https://github.com/papi-ux/polaris";
    changelog = "https://github.com/papi-ux/polaris/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "polaris";
  };
})
