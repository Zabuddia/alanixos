{
  lib,
  buildKodiAddon,
  fetchFromGitHub,
}:

buildKodiAddon rec {
  pname = "navidrome";
  namespace = "plugin.kodi.navidrome";
  version = "0.5.8";

  src = fetchFromGitHub {
    owner = "colinfredynand";
    repo = "plugin.kodi.navidrome";
    rev = "v${version}";
    hash = "sha256-sgjyVJvDvUhMK6QpDB2p8jmeVSkKKKECiqnL6lnBm4E=";
  };

  meta = {
    description = "Kodi client for browsing and streaming music from Navidrome";
    homepage = "https://github.com/colinfredynand/plugin.kodi.navidrome";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.all;
  };
}
