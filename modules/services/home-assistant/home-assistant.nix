{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.home-assistant;
  yamlFormat = pkgs.formats.yaml { };

  baseConfig = {
    default_config = { };

    homeassistant = {
      name = cfg.name;
      time_zone = config.time.timeZone;
      unit_system = cfg.unitSystem;
    };

  };
in
{
  options.alanix.home-assistant = {
    enable = lib.mkEnableOption "Home Assistant (Alanix)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.home-assistant;
      defaultText = lib.literalExpression "pkgs.home-assistant";
      description = "Home Assistant package to use.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Home";
      description = "Name of the Home Assistant location.";
    };

    unitSystem = lib.mkOption {
      type = lib.types.enum [ "metric" "us_customary" ];
      default = "us_customary";
      description = "Unit system used by Home Assistant.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
      default = [ "0.0.0.0" "::" ];
      description = "IPv4 or IPv6 addresses on which the Home Assistant web server listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8123;
      description = "Home Assistant web interface port.";
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hass";
      description = "Persistent Home Assistant configuration and state directory.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow access to the Home Assistant web interface through the host firewall.";
    };

    openFirewallForComponents = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open additional firewall ports required by configured integrations.";
    };

    config = lib.mkOption {
      type = lib.types.attrsOf yamlFormat.type;
      default = { };
      example = {
        automation = [
          {
            alias = "Turn on a light at sunset";
            triggers = [
              {
                trigger = "sun";
                event = "sunset";
              }
            ];
            actions = [
              {
                action = "light.turn_on";
                target.entity_id = "light.porch";
              }
            ];
          }
        ];
      };
      description = ''
        Declarative Home Assistant configuration recursively merged over the
        Alanix base configuration. Values here take precedence over the
        dedicated name, unitSystem, listenAddress, and port options. Lists and
        attribute sets can be extended from additional Nix modules as the home
        automation setup grows.
      '';
    };

    extraComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "default_config"
        "esphome"
        "met"
      ] ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch [
        "rpi_power"
      ];
      description = ''
        Home Assistant integrations whose Python dependencies should be
        included even when the integration is configured through the UI.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "python3Packages: [ ]";
      description = "Additional Python packages included in the Home Assistant environment.";
    };

    customComponents = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packaged custom Home Assistant integrations to install.";
    };

    customLovelaceModules = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packaged custom Lovelace cards to install.";
    };

    lovelaceConfig = lib.mkOption {
      type = lib.types.nullOr yamlFormat.type;
      default = null;
      description = "Declarative configuration for the main Lovelace dashboard.";
    };

    themes = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packaged Home Assistant themes to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" (toString cfg.configDir);
        message = "alanix.home-assistant.configDir must be an absolute path.";
      }
    ];

    services.home-assistant = {
      enable = true;
      inherit (cfg)
        configDir
        customComponents
        customLovelaceModules
        extraComponents
        extraPackages
        lovelaceConfig
        openFirewallForComponents
        package
        themes
        ;
      config = lib.recursiveUpdate baseConfig cfg.config;

      # Keep configuration.yaml owned by Nix. Home Assistant's runtime state,
      # onboarding data, and UI-managed device registry remain writable in
      # configDir.
      configWritable = false;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
