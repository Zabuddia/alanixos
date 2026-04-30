{ config, lib, name, nixosConfig, ... }:

let
  cfg = config.desktop;
  profileRoot = ./desktop-profiles;
  families = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir profileRoot)
  );
  profileEntries = lib.flatten (
    map
      (family:
        let
          familyRoot = profileRoot + "/${family}";
          profileFiles = lib.filterAttrs
            (file: type: type == "regular" && lib.hasSuffix ".nix" file)
            (builtins.readDir familyRoot);
        in
        map
          (file: {
            name = "${family}/${lib.removeSuffix ".nix" file}";
            path = familyRoot + "/${file}";
          })
          (builtins.attrNames profileFiles))
      families
  );
  profiles = map (profile: profile.name) profileEntries;
in
{
  imports = map (profile: profile.path) profileEntries;

  options.desktop = {
    enable = lib.mkEnableOption "desktop essentials for this user";

    profile = lib.mkOption {
      type = lib.types.enum profiles;
      default = "sway/default";
      description = "Home Manager desktop profile to enable for this user.";
    };
  };

  config._assertions = lib.optionals cfg.enable [
    {
      assertion = nixosConfig.alanix.desktop.enable;
      message = "alanix.users.accounts.${name}.desktop.enable requires alanix.desktop.enable = true.";
    }
  ];
}
