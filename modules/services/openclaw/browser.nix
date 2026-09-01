{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.browser;
in
{
  options.alanix.openclaw.browser = {
    enable = lib.mkEnableOption "an isolated OpenClaw-managed Chromium browser";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.chromium;
      defaultText = lib.literalExpression "pkgs.chromium";
      description = "Chromium-family browser used by OpenClaw automation.";
    };

    headless = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the managed browser without displaying its windows.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.browser requires alanix.openclaw.gateway.enable.";
      }
    ];

    alanix.openclaw = {
      packages = [ cfg.package ];
      gateway.config = {
        browser = {
          enabled = true;
          executablePath = lib.getExe cfg.package;
          inherit (cfg) headless;
        };
        tools.alsoAllow = [ "browser" ];
      };
    };
  };
}
