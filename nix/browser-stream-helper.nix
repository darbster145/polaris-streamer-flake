{
  lib,
  stdenv,
  buildGoModule,
  src,
  version,
}:

buildGoModule {
  pname = "polaris-browser-stream-helper";
  inherit src version;

  modRoot = "browser_stream_helper";
  vendorHash = "sha256-MEQl1/E6vm+wGRwNWNaRiXaoZZ+bEzi8ItVXEexHujI=";
  subPackages = [ "." ];

  # Match the PIE and linker hardening used by upstream's Linux CMake target.
  # Append in the hook: this nixpkgs revision forwards a top-level GOFLAGS
  # argument as well as env.GOFLAGS, which makes stdenv reject the duplicate.
  preBuild = lib.optionalString stdenv.hostPlatform.isLinux ''
    export GOFLAGS="''${GOFLAGS:-} -buildmode=pie"
  '';
  ldflags = [
    "-s"
    "-w"
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "-linkmode=external"
    "-extldflags=-Wl,-z,relro,-z,now"
  ];

  postInstall = ''
    mv "$out/bin/browser_stream_helper" "$out/bin/polaris-browser-stream-helper"
  '';

  meta = {
    description = "Polaris experimental Browser Stream WebTransport helper";
    homepage = "https://github.com/papi-ux/polaris";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "polaris-browser-stream-helper";
  };
}
