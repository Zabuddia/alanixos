{
  stdenv,
  lib,
  fetchurl,
  autoPatchelfHook,
  wrapGAppsHook3,
  gtk3,
  webkitgtk_4_1,
  libsoup_3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "opensave";
  version = "2.3.1";

  src = fetchurl {
    url = "https://github.com/Liquid-co/OpenSave/releases/download/v${finalAttrs.version}/opensave-linux-amd64.tar.gz";
    hash = "sha256-fy322nfzYzR2RevSK5xdajsu3u6IXxSaqRA7+Ge7tf4=";
  };

  sourceRoot = "opensave-linux";
  nativeBuildInputs = [
    autoPatchelfHook
    wrapGAppsHook3
  ];
  buildInputs = [
    gtk3
    webkitgtk_4_1
    libsoup_3
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 opensave-cli "$out/bin/opensave"
    ln -s opensave "$out/bin/opensave-cli"
    install -Dm755 opensave "$out/bin/opensave-gui"
    install -Dm644 opensave.png "$out/share/icons/hicolor/512x512/apps/opensave.png"
    install -Dm644 man/opensave.1 "$out/share/man/man1/opensave.1"
    install -Dm644 completions/opensave.bash "$out/share/bash-completion/completions/opensave"
    install -Dm644 completions/opensave.fish "$out/share/fish/vendor_completions.d/opensave.fish"
    install -Dm644 completions/_opensave "$out/share/zsh/site-functions/_opensave"

    runHook postInstall
  '';

  meta = {
    description = "Peer-to-peer, versioned game-save synchronization";
    homepage = "https://github.com/Liquid-co/OpenSave";
    license = lib.licenses.mit;
    mainProgram = "opensave";
    platforms = [ "x86_64-linux" ];
  };
})
