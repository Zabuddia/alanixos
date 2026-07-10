{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.syncthing;
  bulkCfg = cfg.bulkStorage;

  hasValue = value: value != null && value != "";

  parentPrefixes =
    relativePath:
    let
      parts = lib.splitString "/" relativePath;
      parentCount = (builtins.length parts) - 1;
    in
      builtins.genList
        (idx: lib.concatStringsSep "/" (lib.take (idx + 1) parts))
        parentCount;

  sourceRoot = "${bulkCfg.mountPoint}/syncthing";
  targetPath = relativePath: "${cfg.syncRoot}/${relativePath}";
  sourcePath = relativePath: "${sourceRoot}/${relativePath}";
  targetPaths = map targetPath bulkCfg.paths;
  parentPaths = lib.unique (lib.flatten (map parentPrefixes bulkCfg.paths));
  pathIsRelative = path: hasValue path && !(lib.hasPrefix "/" path);

  bindMounts =
    builtins.listToAttrs (
      map
        (relativePath:
          lib.nameValuePair (targetPath relativePath) {
            device = sourcePath relativePath;
            fsType = "none";
            options = [ "bind" "nofail" ];
            depends = [ bulkCfg.mountPoint ];
          })
        bulkCfg.paths
    );

  tmpfiles =
    [
      "d ${bulkCfg.mountPoint} 0755 root root - -"
      "d ${sourceRoot} 0750 ${cfg.user} users - -"
    ]
    ++ map
      (relativePath: "d ${sourceRoot}/${relativePath} 0750 ${cfg.user} users - -")
      parentPaths
    ++ map
      (relativePath: "d ${sourceRoot}/${relativePath} 0750 ${cfg.user} users - -")
      bulkCfg.paths;

  mediaServices =
    builtins.listToAttrs (
      map
        (serviceName:
          lib.nameValuePair serviceName {
            unitConfig.RequiresMountsFor = lib.mkAfter [ (targetPath "media") ];
          })
        bulkCfg.mediaServices
    );
in
{
  options.alanix.syncthing.bulkStorage = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "HDD-backed Syncthing bulk paths";

        device = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Block device for the bulk filesystem.";
        };

        mountPoint = lib.mkOption {
          type = lib.types.str;
          default = "/srv/bulk";
          description = "Mount point for the bulk filesystem.";
        };

        fsType = lib.mkOption {
          type = lib.types.str;
          default = "xfs";
          description = "Filesystem type used by the bulk device.";
        };

        mountOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "nofail" "x-systemd.device-timeout=10s" ];
          description = "Mount options for the bulk filesystem.";
        };

        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Relative paths under alanix.syncthing.syncRoot to bind from bulk storage.";
        };

        mediaServices = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Service units that should wait for the bulk-backed media path.";
        };
      };
    };
    default = { };
    description = "Declarative HDD-backed storage for selected Syncthing paths.";
  };

  config = lib.mkIf bulkCfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.enable;
          message = "alanix.syncthing.bulkStorage requires alanix.syncthing.enable = true.";
        }
        {
          assertion = hasValue bulkCfg.device;
          message = "alanix.syncthing.bulkStorage.device must be set when bulkStorage is enabled.";
        }
        {
          assertion = hasValue bulkCfg.mountPoint && lib.hasPrefix "/" bulkCfg.mountPoint;
          message = "alanix.syncthing.bulkStorage.mountPoint must be an absolute path.";
        }
        {
          assertion = lib.unique bulkCfg.paths == bulkCfg.paths;
          message = "alanix.syncthing.bulkStorage.paths must not contain duplicates.";
        }
        {
          assertion = lib.all pathIsRelative bulkCfg.paths;
          message = "alanix.syncthing.bulkStorage.paths entries must be non-empty relative paths.";
        }
        {
          assertion = bulkCfg.mediaServices == [ ] || builtins.elem "media" bulkCfg.paths;
          message = "alanix.syncthing.bulkStorage.mediaServices requires 'media' in bulkStorage.paths.";
        }
        {
          assertion = lib.unique bulkCfg.mediaServices == bulkCfg.mediaServices;
          message = "alanix.syncthing.bulkStorage.mediaServices must not contain duplicates.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages =
        [ pkgs.rsync ]
        ++ lib.optional (bulkCfg.fsType == "xfs") pkgs.xfsprogs;

      fileSystems =
        {
          "${bulkCfg.mountPoint}" = {
            device = bulkCfg.device;
            fsType = bulkCfg.fsType;
            options = bulkCfg.mountOptions;
          };
        }
        // bindMounts;

      systemd.tmpfiles.rules = tmpfiles;

      systemd.services =
        {
          syncthing.unitConfig.RequiresMountsFor = lib.mkAfter targetPaths;
        }
        // mediaServices;
    })
  ]);
}
