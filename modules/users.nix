{ config, lib, pkgs, pkgs-unstable, ... }:

let
  inherit (lib) types;

  cfg = config.alanix.users;
  featureFiles =
    builtins.attrNames (
      lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".nix" name)
        (builtins.readDir ./users)
    );

  features =
    map
      (name: import (./users + "/${name}") {
        inherit config lib pkgs pkgs-unstable;
      })
      featureFiles;

  featureOptions =
    builtins.foldl'
      lib.recursiveUpdate
      { }
      (map (feature: feature.options or { }) features);

  enabledAccounts = lib.filterAttrs (_: userCfg: userCfg.enable) cfg.accounts;
  homeEnabledAccounts = lib.filterAttrs (_: userCfg: userCfg.enable && userCfg.home.enable) cfg.accounts;
  internalHomeModules = config.alanix._internal.homeModules;
  internalHomeModuleUsers = builtins.attrNames internalHomeModules;

  mkHomeFiles = files:
    lib.mapAttrs
      (_: fileCfg:
        lib.filterAttrs (_: value: value != null) {
          inherit (fileCfg) text source executable;
          force = if fileCfg.force then true else null;
        })
      files;

  accountNeedsHome = username: userCfg:
    userCfg.home.files != { }
    || userCfg.home.packages != [ ]
    || userCfg.home.unstablePackages != [ ]
    || builtins.hasAttr username internalHomeModules
    || lib.any (feature: feature.isEnabled userCfg) features;

  featureAssertionsFor = feature:
    if feature ? assertions
    then feature.assertions
    else (_username: _userCfg: [ ]);

  mkHomeConfig = username: userCfg:
    lib.mkMerge (
      [
        {
          home.username = username;
          programs.home-manager.enable = true;
        }

        (lib.mkIf (userCfg.home.directory != null) {
          home.homeDirectory = userCfg.home.directory;
        })

        (lib.mkIf (userCfg.home.stateVersion != null) {
          home.stateVersion = userCfg.home.stateVersion;
        })
      ]
      ++ map (feature: feature.homeConfig username userCfg) features
      ++ [
        (lib.mkIf (userCfg.home.files != { }) {
          home.file = mkHomeFiles userCfg.home.files;
        })

        (lib.mkIf (userCfg.home.packages != [ ] || userCfg.home.unstablePackages != [ ]) {
          home.packages = userCfg.home.packages ++ userCfg.home.unstablePackages;
        })
      ]
      ++ lib.attrByPath [ username ] [ ] internalHomeModules
    );
in
{
  options.alanix._internal.homeModules = lib.mkOption {
    type = types.attrsOf (types.listOf types.attrs);
    default = { };
    internal = true;
    visible = false;
    description = "Internal Home Manager fragments contributed by non-user modules.";
  };

  options.alanix.users = {
    mutableUsers = lib.mkOption {
      type = types.bool;
      description = "Whether user accounts are mutable outside Nix.";
    };

    accounts = lib.mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options =
          {
            enable = lib.mkEnableOption "managed user ${name}";

            isNormalUser = lib.mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Whether this account is a normal user.";
            };

            extraGroups = lib.mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional groups for the user.";
            };

            hashedPasswordFile = lib.mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to the hashed password file for the user.";
            };

            home = {
              enable = lib.mkEnableOption "Home Manager config for ${name}";

              directory = lib.mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Home directory for the user.";
              };

              stateVersion = lib.mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Home Manager state version.";
              };

              files = lib.mkOption {
                type = types.attrsOf (types.submodule {
                  options = {
                    text = lib.mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Literal file contents.";
                    };

                    source = lib.mkOption {
                      type = types.nullOr types.path;
                      default = null;
                      description = "Source path for the file.";
                    };

                    force = lib.mkOption {
                      type = types.bool;
                      default = false;
                      description = "Whether to overwrite an existing file.";
                    };

                    executable = lib.mkOption {
                      type = types.nullOr types.bool;
                      default = null;
                      description = "Whether the generated file should be executable.";
                    };
                  };
                });
                default = { };
                description = "Home Manager files declared for the user.";
              };

              packages = lib.mkOption {
                type = types.listOf types.package;
                default = [ ];
                description = "Additional Home Manager packages from the stable package set.";
              };

              unstablePackages = lib.mkOption {
                type = types.listOf types.package;
                default = [ ];
                description = "Additional Home Manager packages from pkgs-unstable.";
              };
            };
          }
          // featureOptions;
      }));
      default = { };
      description = "Declarative alanix-managed user accounts.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.accounts != { }) {
      users.mutableUsers = cfg.mutableUsers;
    })

    (lib.mkIf (enabledAccounts != { }) {
      users.users = lib.mapAttrs
        (_: userCfg:
          lib.filterAttrs (_: value: value != null) {
            isNormalUser = userCfg.isNormalUser;
            extraGroups = userCfg.extraGroups;
            hashedPasswordFile = userCfg.hashedPasswordFile;
          })
        enabledAccounts;
    })

    (lib.mkIf (homeEnabledAccounts != { }) {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { inherit pkgs-unstable; };
      home-manager.users = lib.mapAttrs mkHomeConfig homeEnabledAccounts;
    })

    {
      assertions =
        lib.flatten (
          lib.mapAttrsToList
            (username: userCfg:
              let
                fileAssertions =
                  lib.mapAttrsToList
                    (path: fileCfg: {
                      assertion = lib.length (lib.filter (value: value != null) [ fileCfg.text fileCfg.source ]) == 1;
                      message = "alanix.users.accounts.${username}.home.files.${path}: set exactly one of text or source.";
                    })
                    userCfg.home.files;

                featureAssertions =
                  lib.flatten (map (feature: featureAssertionsFor feature username userCfg) features);
              in
              lib.optionals userCfg.enable (
                [
                  {
                    assertion = userCfg.isNormalUser != null;
                    message = "alanix.users.accounts.${username}.isNormalUser must be set when the account is enabled.";
                  }
                  {
                    assertion = userCfg.hashedPasswordFile != null;
                    message = "alanix.users.accounts.${username}.hashedPasswordFile must be set when the account is enabled.";
                  }
                  {
                    assertion = !accountNeedsHome username userCfg || userCfg.home.enable;
                    message = "alanix.users.accounts.${username}: enable home when using Home Manager files, packages, or account features.";
                  }
                ]
                ++ lib.optionals userCfg.home.enable [
                  {
                    assertion = userCfg.home.directory != null;
                    message = "alanix.users.accounts.${username}.home.directory must be set when home is enabled.";
                  }
                  {
                    assertion = userCfg.home.stateVersion != null;
                    message = "alanix.users.accounts.${username}.home.stateVersion must be set when home is enabled.";
                  }
                ]
                ++ fileAssertions
                ++ featureAssertions
              )
            )
            cfg.accounts
        )
        ++ lib.flatten (map
          (username:
            let
              userCfg = lib.attrByPath [ username ] null cfg.accounts;
            in
            [
              {
                assertion = userCfg != null && userCfg.enable;
                message = "Internal Home Manager config targets alanix.users.accounts.${username}, but that account is not enabled.";
              }
              {
                assertion = userCfg != null && userCfg.enable && userCfg.home.enable;
                message = "Internal Home Manager config targets alanix.users.accounts.${username}, but home.enable is not set.";
              }
            ])
          internalHomeModuleUsers);
    }
  ];
}
