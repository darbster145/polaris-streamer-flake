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
    url = "https://github.com/LizardByte/build-deps/releases/download/v2026.516.30821/Linux-x86_64-ffmpeg.tar.gz";
    hash = "sha256-VT+4qP2FaizCoIBBbBkzbYw4YOvGhuBUoZxWL0IYVZo=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "polaris-stream";
  version = "1.2.0";

  src = fetchFromGitHub {
    owner = "papi-ux";
    repo = "polaris";
    rev = "c639383673d07234d59c7be1c97f7eaa8ae6f0b4";
    fetchSubmodules = true;
    hash = "sha256-ugF+pEoUB/2ovp90LR26sFCbFOx4RX8BGArPQQpjIng=";
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
      --prefix PATH : ${lib.makeBinPath [
        grim
        labwc
        wlr-randr
        which
        xdpyinfo
        xwayland
      ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
        avahi
        libglvnd
        mesa
      ]}
  '';

  meta = {
    description = "Self-hosted game stream host for Moonlight";
    homepage = "https://github.com/papi-ux/polaris";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "polaris";
  };
})
