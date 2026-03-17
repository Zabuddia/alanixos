{ pkgs-unstable, ... }:
{
  programs.chromium = {
    enable = true;
    package = pkgs-unstable.ungoogled-chromium;
    commandLineArgs = [
      "--ozone-platform=wayland"
      "--disable-features=VaapiVideoDecodeLinuxGL"
      "--homepage=about:blank"
      "--no-default-browser-check"
    ];
  };
}
