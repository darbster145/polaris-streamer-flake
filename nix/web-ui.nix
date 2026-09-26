{
  buildNpmPackage,
  src,
  version,
}:

buildNpmPackage {
  pname = "polaris-web-ui";
  inherit src version;

  npmDepsHash = "sha256-whATRIwRQMPw6lt9Zy4nuSSkAC6w4yvBzOjxY03yYfk=";
  env.POLARIS_CONSOLE_VERSION = version;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r build/assets/web/. "$out/"
    runHook postInstall
  '';
}
