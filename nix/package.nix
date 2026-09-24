{
  stdenv,
  lib,
  fetchFromGitHub,
  fetchzip,
  cmake,
  ninja,
  pkg-config,
  nodejs,
  python3,
  importNpmLock,
  makeWrapper,
  nix-update-script,
  boost,
  openssl,
  curl,
  libevdev,
  libei,
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
    # Match upstream's NVENC 13.0-compatible bundle. fetchzip needs the unpacked NAR hash.
    url = "https://github.com/LizardByte/build-deps/releases/download/v2026.713.132551/Linux-x86_64-ffmpeg.tar.gz";
    hash = "sha256-nHL+JxxMbR5fva/w1tt0BqcDowSAojuV8504he/wbsg=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "polaris-stream";
  version = "1.4.12";

  strictDeps = true;

  src = fetchFromGitHub {
    owner = "papi-ux";
    repo = "polaris";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-QqVhtifdsKl+agDZV8PiPQ/tlB2lQA7YVNZ8X9AQ+90=";
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
    python3
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
    libei
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
    "-DPOLARIS_BUILD_MULTISEAT_WORKER=OFF"
    "-DPOLARIS_SYSTEM_WAYLAND_PROTOCOLS=ON"
    "-DPOLARIS_DOWNLOAD_PREPARED_FFMPEG=OFF"
    "-DFFMPEG_PREPARED_BINARIES=${preparedFfmpeg}"
    "-DBOOST_USE_STATIC=OFF"
    "-DNPM_OFFLINE=ON"
    # The NixOS module owns the service; never install into systemd's store path.
    "-DCMAKE_DISABLE_FIND_PACKAGE_Systemd=ON"
    "-DPOLARIS_UDEV_RULES_DIR=${placeholder "out"}/lib/udev/rules.d"
    "-DPOLARIS_MODULES_LOAD_DIR=${placeholder "out"}/lib/modules-load.d"
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
    polarisVersionOutput="$(XDG_CONFIG_HOME="$TMPDIR/polaris-install-check" "$out/bin/polaris" --version)"
    printf '%s\n' "$polarisVersionOutput"
    [[ "$polarisVersionOutput" == *"Polaris version: ${finalAttrs.version} "* ]]
    runHook postInstallCheck
  '';

  passthru = {
    updateScript = nix-update-script {
      extraArgs = [ "--flake" ];
    };
    buildFeatures = {
      browserStream = false;
      cudaCapture = false;
      multiseatWorker = false;
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
