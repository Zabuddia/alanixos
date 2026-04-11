{ config, lib, pkgs, pkgs-unstable, allHosts, ... }:

let
  inherit (lib) types;

  cfg = config.alanix.users;

  featureModules = [
    ./users/azahar.nix
    ./users/chromium.nix
    ./users/desktop.nix
    ./users/dolphin.nix
    ./users/git.nix
    ./users/librewolf.nix
    ./users/melonds.nix
    ./users/nextcloud-client.nix
    ./users/ryubing.nix
    ./users/sh.nix
    ./users/ssh.nix
    ./users/syncthing-tray.nix
    ./users/trayscale.nix
    ./users/vscode.nix
  ];

  assertionType = types.submodule {
    options = {
      assertion = lib.mkOption {
        type = types.bool;
        description = "Whether the assertion passes.";
      };

      message = lib.mkOption {
        type = types.str;
        description = "Assertion failure message.";
      };
    };
  };

  mkHomeFiles = files:
    lib.mapAttrs
      (_: fileCfg:
        lib.filterAttrs (_: value: value != null) {
          inherit (fileCfg) text source executable;
          force = if fileCfg.force then true else null;
        })
      files;

  accountModule = { name, config, ... }:
    let
      fileAssertions =
        lib.mapAttrsToList
          (path: fileCfg: {
            assertion = lib.length (lib.filter (value: value != null) [ fileCfg.text fileCfg.source ]) == 1;
            message = "alanix.users.accounts.${name}.home.files.${path}: set exactly one of text or source.";
          })
          config.home.files;

      needsHome =
        config.home.files != { }
        || config.home.packages != [ ]
        || config.home.unstablePackages != [ ]
        || config.home.modules != [ ];
    in
    {
      options = {
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

        sshPublicKey = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Primary SSH public key for this account. Written to ~/.ssh/id_ed25519.pub.";
        };

        authorizedHosts = lib.mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Names of alanix hosts whose sshPublicKey for this account is added to authorized_keys on this host. Mirrors the wireguard peers pattern.";
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

          modules = lib.mkOption {
            type = types.listOf types.raw;
            default = [ ];
            description = "Additional Home Manager modules for this account.";
          };
        };

        _assertions = lib.mkOption {
          type = types.listOf assertionType;
          default = [ ];
          internal = true;
          visible = false;
          description = "Internal assertions contributed by account feature modules.";
        };
      };

      config._assertions =
        lib.optionals config.enable (
          [
            {
              assertion = config.isNormalUser != null;
              message = "alanix.users.accounts.${name}.isNormalUser must be set when the account is enabled.";
            }
            {
              assertion = config.hashedPasswordFile != null;
              message = "alanix.users.accounts.${name}.hashedPasswordFile must be set when the account is enabled.";
            }
            {
              assertion = !needsHome || config.home.enable;
              message = "alanix.users.accounts.${name}: enable home when using Home Manager files, packages, or account features.";
            }
          ]
          ++ lib.optionals config.home.enable [
            {
              assertion = config.home.directory != null;
              message = "alanix.users.accounts.${name}.home.directory must be set when home is enabled.";
            }
            {
              assertion = config.home.stateVersion != null;
              message = "alanix.users.accounts.${name}.home.stateVersion must be set when home is enabled.";
            }
          ]
          ++ fileAssertions
        );
    };

  accountType = types.submoduleWith {
    specialArgs = {
      inherit pkgs pkgs-unstable;
      nixosConfig = config;
    };
    modules = [ accountModule ] ++ featureModules;
  };

  enabledAccounts = lib.filterAttrs (_: userCfg: userCfg.enable) cfg.accounts;
  homeEnabledAccounts = lib.filterAttrs (_: userCfg: userCfg.enable && userCfg.home.enable) cfg.accounts;
  sshPublicKeyAccounts =
    lib.filterAttrs
      (_: userCfg:
        userCfg.enable
        && userCfg.home.enable
        && userCfg.home.directory != null
        && userCfg.sshPublicKey != null)
      cfg.accounts;
  mkHomeConfig = username: userCfg: {
    imports = userCfg.home.modules;
    home.username = username;
    home.homeDirectory = userCfg.home.directory;
    home.stateVersion = userCfg.home.stateVersion;
    home.file =
      mkHomeFiles userCfg.home.files
      // lib.optionalAttrs (userCfg.sshPublicKey != null) {
        ".ssh/id_ed25519.pub" = {
          text = userCfg.sshPublicKey;
          force = true;
        };
      };
    home.packages = userCfg.home.packages ++ userCfg.home.unstablePackages;
    programs.home-manager.enable = true;
  };
in
{
  options.alanix.users = {
    mutableUsers = lib.mkOption {
      type = types.bool;
      description = "Whether user accounts are mutable outside Nix.";
    };

    accounts = lib.mkOption {
      type = types.attrsOf accountType;
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
        (username: userCfg:
          lib.filterAttrs (_: value: value != null) {
            isNormalUser = userCfg.isNormalUser;
            extraGroups = userCfg.extraGroups;
            hashedPasswordFile = userCfg.hashedPasswordFile;
          } // {
            openssh.authorizedKeys.keys =
              lib.mapAttrsToList
                (_: hostCfg: hostCfg.config.alanix.users.accounts.${username}.sshPublicKey)
                (lib.filterAttrs
                  (hostName: hostCfg:
                    builtins.elem hostName userCfg.authorizedHosts
                    && (hostCfg.config.alanix.users.accounts ? ${username})
                    && hostCfg.config.alanix.users.accounts.${username}.enable
                    && hostCfg.config.alanix.users.accounts.${username}.sshPublicKey != null)
                  allHosts);
          })
        enabledAccounts;
    })

    (lib.mkIf (homeEnabledAccounts != { }) {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { inherit pkgs-unstable; };
      home-manager.backupFileExtension = "hm-backup";
      home-manager.users = lib.mapAttrs mkHomeConfig homeEnabledAccounts;
    })

    (lib.mkIf (sshPublicKeyAccounts != { }) {
      system.activationScripts.alanixUserSshPublicKeys.text = lib.concatStringsSep "\n" (
        lib.mapAttrsToList
          (username: userCfg:
            let
              sshDir = "${userCfg.home.directory}/.ssh";
              pubKeyPath = "${sshDir}/id_ed25519.pub";
            in
            ''
              install -d -m 0700 -o ${username} -g users ${lib.escapeShellArg sshDir}
              printf '%s\n' ${lib.escapeShellArg userCfg.sshPublicKey} > ${lib.escapeShellArg pubKeyPath}
              chown ${lib.escapeShellArg "${username}:"} ${lib.escapeShellArg pubKeyPath}
              chmod 0644 ${lib.escapeShellArg pubKeyPath}
            '')
          sshPublicKeyAccounts
      );
    })

    {
      assertions = lib.flatten (
        lib.mapAttrsToList (_: userCfg: lib.optionals userCfg.enable userCfg._assertions) cfg.accounts
      );
    }
  ];
}
