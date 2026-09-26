{
  stdenv,
  lib,
  config,
  callPackage,
  fetchFromGitHub,
  fetchzip,
  cmake,
  ninja,
  pkg-config,
  python3,
  makeWrapper,
  autoPatchelfHook,
  autoAddDriverRunpath,
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
  xdg-utils,
  bubblewrap,
  pulseaudio,
  xrandr,
  pciutils,
  cudaPackages,
  cudaSupport ? config.cudaSupport,
  enableBrowserStream ? true,
}:

let
  stdenv' = if cudaSupport then cudaPackages.backendStdenv else stdenv;
  ffmpegArch =
    {
      x86_64-linux = "Linux-x86_64";
      aarch64-linux = "Linux-aarch64";
    }
    .${stdenv.hostPlatform.system};
  preparedFfmpeg = fetchzip {
    # Match upstream's NVENC 13.0-compatible bundle. fetchzip needs the unpacked NAR hash.
    url = "https://github.com/LizardByte/build-deps/releases/download/v2026.713.132551/${ffmpegArch}-ffmpeg.tar.gz";
    hash =
      {
        x86_64-linux = "sha256-nHL+JxxMbR5fva/w1tt0BqcDowSAojuV8504he/wbsg=";
        aarch64-linux = "sha256-/4EW4ZWZxIYbMjIS1XujoCbQTtLmOy4j2roPxJaAXrw=";
      }
      .${stdenv.hostPlatform.system};
  };
in
stdenv'.mkDerivation (finalAttrs: {
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

  webUI = callPackage ./web-ui.nix {
    inherit (finalAttrs) src version;
  };

  browserStreamHelper =
    if enableBrowserStream then
      callPackage ./browser-stream-helper.nix {
        inherit (finalAttrs) src version;
      }
    else
      null;

  patches = [ ./patches/prebuilt-web-ui.patch ];

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    makeWrapper
    autoPatchelfHook
    autoAddDriverRunpath
    wayland-scanner
    shaderc
  ]
  ++ lib.optionals cudaSupport [
    cudaPackages.cuda_nvcc
    (lib.getDev cudaPackages.cuda_cudart)
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
  ]
  ++ lib.optionals cudaSupport [ cudaPackages.cuda_cudart ];

  # These libraries are opened with dlopen, so the linker cannot retain them.
  # Put them in RUNPATH instead of leaking LD_LIBRARY_PATH to launched games.
  runtimeDependencies = [
    avahi
    libgbm
    libxrandr
    libxcb
    libglvnd
    vulkan-loader
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-GNinja"
    (lib.cmakeBool "POLARIS_ENABLE_CUDA" cudaSupport)
    (lib.cmakeBool "CUDA_FAIL_ON_MISSING" cudaSupport)
    (lib.cmakeBool "POLARIS_ALLOW_CUDA_DISABLED_ON_NVIDIA" (!cudaSupport))
    (lib.cmakeBool "POLARIS_ENABLE_BROWSER_STREAM" enableBrowserStream)
    "-DPOLARIS_BUILD_MULTISEAT_WORKER=OFF"
    "-DPOLARIS_SYSTEM_WAYLAND_PROTOCOLS=ON"
    "-DPOLARIS_DOWNLOAD_PREPARED_FFMPEG=OFF"
    "-DFFMPEG_PREPARED_BINARIES=${preparedFfmpeg}"
    "-DBOOST_USE_STATIC=OFF"
    "-DPOLARIS_ENABLE_NATIVE_ARCH=OFF"
    "-DPOLARIS_WEB_UI_PREBUILT=${finalAttrs.webUI}"
    # The NixOS module owns the service; never install into systemd's store path.
    "-DCMAKE_DISABLE_FIND_PACKAGE_Systemd=ON"
    "-DPOLARIS_UDEV_RULES_DIR=${placeholder "out"}/lib/udev/rules.d"
    "-DPOLARIS_MODULES_LOAD_DIR=${placeholder "out"}/lib/modules-load.d"
  ];

  postPatch = lib.optionalString enableBrowserStream ''
    substituteInPlace cmake/targets/common.cmake \
      --replace-fail 'find_program(GO_EXECUTABLE go REQUIRED)' 'set(GO_EXECUTABLE unused)' \
      --replace-fail 'COMMAND "''${GO_EXECUTABLE}" ''${BROWSER_STREAM_HELPER_BUILD_ARGUMENTS} -o "''${BROWSER_STREAM_HELPER_OUTPUT}" .' \
        'COMMAND "''${CMAKE_COMMAND}" -E copy "${finalAttrs.browserStreamHelper}/bin/polaris-browser-stream-helper" "''${BROWSER_STREAM_HELPER_OUTPUT}"'
  '';

  postFixup = ''
    wrapProgram $out/bin/polaris \
      --prefix PATH : ${
        lib.makeBinPath [
          grim
          labwc
          wlr-randr
          which
          xdpyinfo
          xwayland
          xdg-utils
          bubblewrap
          pulseaudio
          xrandr
          pciutils
        ]
      } \
      ${lib.optionalString enableBrowserStream ''--set-default POLARIS_BROWSER_STREAM_HELPER "$out/bin/polaris-browser-stream-helper"''}
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    polarisVersionOutput="$(XDG_CONFIG_HOME="$TMPDIR/polaris-install-check" "$out/bin/polaris" --version)"
    printf '%s\n' "$polarisVersionOutput"
    [[ "$polarisVersionOutput" == *"Polaris version: ${finalAttrs.version} "* ]]
    test -s "$out/assets/web/index.html"
    test -s "$out/lib/udev/rules.d/60-polaris.rules"
    test -s "$out/lib/modules-load.d/60-polaris.conf"
    bash -n "$out/bin/polaris-gamescope-session"
    bash -n "$out/bin/polaris-gamescope-runtime-lib.sh"
    ${lib.optionalString enableBrowserStream ''
      "$out/bin/polaris-browser-stream-helper" -h 2>&1 | grep -F 'UDP HTTPS/WebTransport bind address'
    ''}
    runHook postInstallCheck
  '';

  passthru = {
    updateScript = nix-update-script {
      extraArgs = [ "--flake" ];
    };
    buildFeatures = {
      browserStream = enableBrowserStream;
      cudaCapture = cudaSupport;
      multiseatWorker = false;
    };
  };

  meta = {
    description = "Self-hosted game stream host for Moonlight";
    homepage = "https://github.com/papi-ux/polaris";
    changelog = "https://github.com/papi-ux/polaris/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "polaris";
  };
})
