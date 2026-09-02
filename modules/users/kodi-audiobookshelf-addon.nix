{
  lib,
  buildKodiAddon,
  fetchgit,
  requests,
}:

buildKodiAddon rec {
  pname = "audiobookshelf";
  namespace = "plugin.audio.audiobookshelf";
  version = "2026.7.24";

  src = fetchgit {
    url = "https://github.com/Breezyslasher/Kodi-Addons.git";
    rev = "37b9697c47a174e8f9e51856bafdcd5da76c6941";
    hash = "sha256-Zt9MrN9AWVB3E76h/LVghDPnA8pKwlOfaQYeqoc+ekM=";
    sparseCheckout = [ namespace ];
  };

  sourceDir = namespace;

  # Upstream currently assumes an unencrypted server and always constructs
  # http://HOST:PORT. Accept a complete URL too, so the add-on can use the
  # existing HTTPS reverse proxy without weakening that service.
  postPatch = ''
    substituteInPlace ${namespace}/default.py \
      --replace-fail 'url = f"http://{ip}:{port}"' \
        'url = ip.rstrip("/") if ip.startswith(("http://", "https://")) else f"http://{ip}:{port}"'
  '';

  propagatedBuildInputs = [ requests ];

  meta = {
    description = "Kodi client for streaming and syncing Audiobookshelf media";
    homepage = "https://github.com/Breezyslasher/Kodi-Addons/tree/main/plugin.audio.audiobookshelf";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.all;
  };
}
