{ buildNpmPackage, lib, makeWrapper, nodejs_22 }:
let
  packageJson = builtins.fromJSON (builtins.readFile ./package.json);
in
(buildNpmPackage.override { nodejs = nodejs_22; }) {
  pname = "actual-cli";
  inherit (packageJson) version;
  src = ./.;
  npmDepsHash = "sha256-W06+yIN81Hfnmjrre1FGP2nxY1stffzstfu06yYw6ds=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/actual-cli" "$out/bin"
    cp -r node_modules "$out/lib/actual-cli/"
    makeWrapper ${lib.getExe nodejs_22} "$out/bin/actual" \
      --add-flags "$out/lib/actual-cli/node_modules/@actual-app/cli/dist/cli.js"

    runHook postInstall
  '';

  meta = {
    description = "Official command-line interface for Actual Budget";
    homepage = "https://actualbudget.org/docs/api/cli/";
    license = lib.licenses.mit;
    mainProgram = "actual";
  };
}
