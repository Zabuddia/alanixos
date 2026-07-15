{ config, lib, hostname, allHosts, ... }:

let
  cfg = config.alanix.syncthing;

  hasValue = value: value != null && value != "";

  certSecretName = "syncthing-certs/${hostname}";
  keySecretName = "syncthing-keys/${hostname}";

  userAccount = lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config;
  userHomeDir =
    if userAccount != null && hasValue userAccount.home.directory then
      userAccount.home.directory
    else
      "/home/${cfg.user}";
  userHomeReady =
    userAccount != null
    && userAccount.enable
    && userAccount.home.enable
    && hasValue userAccount.home.directory;
  configDir = "${userHomeDir}/.config/syncthing";

  peerHosts =
    map
      (peerName: {
        name = peerName;
        hostCfg = lib.attrByPath [ peerName ] null allHosts;
      })
      cfg.peers;

  transportConfig =
    if cfg.transport == "tailscale" then
      {
        localAddress = "0.0.0.0";
        localFirewallInterface = config.services.tailscale.interfaceName;
        requireLocal = config.alanix.tailscale.enable && hasValue config.alanix.tailscale.address;
        requireLocalMessage = "alanix.syncthing.transport = \"tailscale\" requires alanix.tailscale.enable = true and alanix.tailscale.address to be set.";
        peerAddress = hostCfg: hostCfg.config.alanix.tailscale.address;
        peerReady = hostCfg: hostCfg.config.alanix.tailscale.enable && hasValue hostCfg.config.alanix.tailscale.address;
        peerMessage = peerName: "alanix.syncthing.peers.${peerName} must reference a host with alanix.tailscale.enable = true and alanix.tailscale.address set when transport = \"tailscale\".";
      }
    else
      null;

  staggeredVersioning = maxAgeDays: {
    type = "staggered";
    params = {
      cleanInterval = "3600";
      maxAge = toString (maxAgeDays * 24 * 3600);
    };
  };

  mediaVersioning = staggeredVersioning 365;
  romVersioning = staggeredVersioning 365;
  romFolderProtection = {
    ignoreDelete = true;
    versioning = romVersioning;
  };

  azaharSystemId = "00000000000000000000000000000000";
  azaharSdCardId = "00000000000000000000000000000000";
  azaharSdmcRelativeBase = "games/azahar-emu/sdmc/Nintendo 3DS/${azaharSystemId}/${azaharSdCardId}";
  azaharNandRelativeBase = "games/azahar-emu/nand/data/${azaharSystemId}";
  azaharLocalSdmcBase =
    ".local/share/azahar-emu/sdmc/Nintendo 3DS/${azaharSystemId}/${azaharSdCardId}";
  azaharLocalNandBase = ".local/share/azahar-emu/nand/data/${azaharSystemId}";

  azaharFolders = {
    "games-roms-3ds" = {
      label = "games/roms/3ds";
      relativePath = "games/roms/3ds";
    } // romFolderProtection;
    "games-azahar-emu-sdmc-title" = {
      label = "${azaharSdmcRelativeBase}/title";
      relativePath = "${azaharSdmcRelativeBase}/title";
      versioning = staggeredVersioning 90;
    };
    "games-azahar-emu-sdmc-extdata" = {
      label = "${azaharSdmcRelativeBase}/extdata";
      relativePath = "${azaharSdmcRelativeBase}/extdata";
      versioning = staggeredVersioning 90;
    };
    "games-azahar-emu-nand-extdata" = {
      label = "${azaharNandRelativeBase}/extdata";
      relativePath = "${azaharNandRelativeBase}/extdata";
      versioning = staggeredVersioning 90;
    };
  };

  dolphinFolders = {
    "games-roms-gamecube" = {
      label = "games/roms/gamecube";
      relativePath = "games/roms/gamecube";
    } // romFolderProtection;
    "games-roms-wii" = {
      label = "games/roms/wii";
      relativePath = "games/roms/wii";
    } // romFolderProtection;
    "games-dolphin-emu-gc" = {
      label = "games/dolphin-emu/GC";
      relativePath = "games/dolphin-emu/GC";
      versioning = staggeredVersioning 90;
    };
    "games-dolphin-emu-wii-title" = {
      label = "games/dolphin-emu/Wii/title";
      relativePath = "games/dolphin-emu/Wii/title";
      versioning = staggeredVersioning 90;
    };
    "games-dolphin-emu-load-riivolution" = {
      label = "games/dolphin-emu/Load/Riivolution";
      relativePath = "games/dolphin-emu/Load/Riivolution";
    };
  };

  melondsFolders = {
    "games-roms-nds" = {
      label = "games/roms/nds";
      relativePath = "games/roms/nds";
    } // romFolderProtection;
    "games-melonds-saves" = {
      label = "games/melonDS/saves";
      relativePath = "games/melonDS/saves";
      versioning = staggeredVersioning 90;
    };
  };

  n64Folders = {
    "games-roms-n64" = {
      label = "games/roms/n64";
      relativePath = "games/roms/n64";
    } // romFolderProtection;
  };

  retroarchFolders = {
    "games-roms-nes" = {
      label = "games/roms/nes";
      relativePath = "games/roms/nes";
    } // romFolderProtection;
    "games-roms-snes" = {
      label = "games/roms/snes";
      relativePath = "games/roms/snes";
    } // romFolderProtection;
    "games-roms-gb" = {
      label = "games/roms/gb";
      relativePath = "games/roms/gb";
    } // romFolderProtection;
    "games-roms-gbc" = {
      label = "games/roms/gbc";
      relativePath = "games/roms/gbc";
    } // romFolderProtection;
    "games-roms-gba" = {
      label = "games/roms/gba";
      relativePath = "games/roms/gba";
    } // romFolderProtection;
    "games-roms-genesis" = {
      label = "games/roms/genesis";
      relativePath = "games/roms/genesis";
    } // romFolderProtection;
    "games-retroarch" = {
      label = "games/retroarch";
      relativePath = "games/retroarch";
      versioning = staggeredVersioning 90;
    };
  };

  edenFolders = {
    "games-eden" = {
      label = "games/Eden";
      relativePath = "games/Eden";
      versioning = staggeredVersioning 90;
    };
    "games-eden-profile" = {
      label = "games/Eden-profile";
      relativePath = "games/Eden-profile";
      versioning = staggeredVersioning 90;
    };
  };

  ryujinxFolders = {
    "games-roms-switch" = {
      label = "games/roms/switch";
      relativePath = "games/roms/switch";
    } // romFolderProtection;
    "games-ryujinx" = {
      label = "games/Ryujinx";
      relativePath = "games/Ryujinx";
      versioning = staggeredVersioning 90;
    };
    "games-ryujinx-save-meta" = {
      label = "games/Ryujinx-saveMeta";
      relativePath = "games/Ryujinx-saveMeta";
      versioning = staggeredVersioning 90;
    };
    "games-ryujinx-save-data-indexer" = {
      label = "games/Ryujinx-saveDataIndexer";
      relativePath = "games/Ryujinx-saveDataIndexer";
      versioning = staggeredVersioning 90;
    };
  };

  moviesFolders = {
    "media-movies" = {
      label = "media/movies";
      relativePath = "media/movies";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  showsFolders = {
    "media-shows" = {
      label = "media/shows";
      relativePath = "media/shows";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  videosFolders = {
    "media-videos" = {
      label = "media/videos";
      relativePath = "media/videos";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  musicFolders = {
    "media-music" = {
      label = "media/music";
      relativePath = "media/music";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  audiobooksFolders = {
    "media-audiobooks" = {
      label = "media/audiobooks";
      relativePath = "media/audiobooks";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  ebooksFolders = {
    "media-ebooks" = {
      label = "media/ebooks";
      relativePath = "media/ebooks";
      user = "buddia";
      group = "users";
      mode = "2775";
      ignorePerms = true;
      ignoreDelete = true;
      versioning = mediaVersioning;
    };
  };

  filebrowserUserDeclarations =
    lib.flatten (
      lib.mapAttrsToList
        (hostName: hostCfg:
          lib.mapAttrsToList
            (userName: userCfg: {
              inherit hostName userName userCfg;
            })
            (lib.attrByPath [ "config" "alanix" "filebrowser" "users" ] { } hostCfg)
        )
        allHosts
    );

  filebrowserSyncedUserDeclarations =
    lib.filter (decl: hasValue decl.userCfg.scope && decl.userCfg.scope != ".") filebrowserUserDeclarations;

  filebrowserUserFolderSetName = userName: "filebrowser-${userName}-files";

  filebrowserUserFolderId =
    scope:
    "filebrowser-${lib.replaceStrings [ "/" " " ] [ "-" "-" ] scope}";

  filebrowserUserFolderSets =
    builtins.listToAttrs (
      map
        (decl:
          let
            scope = decl.userCfg.scope;
          in
          lib.nameValuePair (filebrowserUserFolderSetName decl.userName) {
            ${filebrowserUserFolderId scope} = {
              label = "filebrowser/${scope}";
              relativePath = "filebrowser/${scope}";
              parentMode = "2775";
              group = "users";
              mode = "2775";
              ignorePerms = true;
              versioning = staggeredVersioning 180;
            };
          })
        filebrowserSyncedUserDeclarations
    );

  filebrowserFolderSetNames = builtins.attrNames filebrowserUserFolderSets;

  folderCatalog = {
    emulation-azahar = azaharFolders;
    emulation-dolphin = dolphinFolders;
    emulation-eden = edenFolders;
    emulation-melonds = melondsFolders;
    emulation-n64 = n64Folders;
    emulation-retroarch = retroarchFolders;
    emulation-ryujinx = ryujinxFolders;
    movies = moviesFolders;
    shows = showsFolders;
    videos = videosFolders;
    music = musicFolders;
    audiobooks = audiobooksFolders;
    ebooks = ebooksFolders;
  } // filebrowserUserFolderSets;

  azaharLinks = {
    "${azaharLocalSdmcBase}/title" = {
      relativePath = "${azaharSdmcRelativeBase}/title";
    };
    "${azaharLocalSdmcBase}/extdata" = {
      relativePath = "${azaharSdmcRelativeBase}/extdata";
    };
    "${azaharLocalNandBase}/extdata" = {
      relativePath = "${azaharNandRelativeBase}/extdata";
    };
  };

  dolphinLinks = {
    ".local/share/dolphin-emu/GC" = {
      relativePath = "games/dolphin-emu/GC";
    };
    ".local/share/dolphin-emu/Wii/title" = {
      relativePath = "games/dolphin-emu/Wii/title";
    };
    ".local/share/dolphin-emu/Load/Riivolution" = {
      relativePath = "games/dolphin-emu/Load/Riivolution";
    };
  };

  melondsLinks = {
    ".local/share/melonDS/saves" = {
      relativePath = "games/melonDS/saves";
    };
  };

  edenLinks = {
    ".local/share/eden/nand/user/save" = {
      relativePath = "games/Eden";
    };
    ".local/share/eden/nand/system/save/8000000000000010" = {
      relativePath = "games/Eden-profile";
    };
  };

  ryujinxLinks = {
    ".config/Ryujinx/bis/user/save" = {
      relativePath = "games/Ryujinx";
    };
    ".config/Ryujinx/bis/user/saveMeta" = {
      relativePath = "games/Ryujinx-saveMeta";
    };
    ".config/Ryujinx/bis/system/save/8000000000000000" = {
      relativePath = "games/Ryujinx-saveDataIndexer";
    };
  };

  linkCatalog = {
    emulation-azahar = azaharLinks;
    emulation-dolphin = dolphinLinks;
    emulation-eden = edenLinks;
    emulation-melonds = melondsLinks;
    emulation-ryujinx = ryujinxLinks;
  };

  folderSetAliases = {
    emulation = [
      "emulation-azahar"
      "emulation-dolphin"
      "emulation-eden"
      "emulation-melonds"
      "emulation-n64"
      "emulation-retroarch"
      "emulation-ryujinx"
    ];
    filebrowser-files = filebrowserFolderSetNames;
  };

  linkFolderSetAliases = {
    emulation = [ "emulation-azahar" "emulation-dolphin" "emulation-eden" "emulation-melonds" "emulation-ryujinx" ];
  };

  validFolderSets = lib.unique ((builtins.attrNames folderCatalog) ++ (builtins.attrNames folderSetAliases));
  linkableFolderSets = lib.unique ((builtins.attrNames linkCatalog) ++ (builtins.attrNames linkFolderSetAliases));
  folderSetType = lib.types.enum validFolderSets;
  linkFolderSetType = lib.types.enum linkableFolderSets;

  expandFolderSetsWithAliases =
    aliases: folderSets:
    lib.unique (lib.flatten (map (folderSet: aliases.${folderSet} or [ folderSet ]) folderSets));

  expandFolderSets = expandFolderSetsWithAliases folderSetAliases;
  expandLinkFolderSets = expandFolderSetsWithAliases linkFolderSetAliases;

  effectiveFolderSets = expandFolderSets cfg.folderSets;
  effectiveLinkFolderSets = expandLinkFolderSets cfg.linkFolderSets;

  activeExternalDevices = lib.filterAttrs (_: deviceCfg: hasValue deviceCfg.id) cfg.externalDevices;

  externalDeviceFolderSets = deviceCfg: expandFolderSets deviceCfg.folderSets;

  folderSetMembers =
    folderSet:
    builtins.attrNames (
      lib.filterAttrs
        (_: hostCfg:
          hostCfg.config.alanix.syncthing.enable
          && builtins.elem folderSet (expandFolderSets hostCfg.config.alanix.syncthing.folderSets)
        )
        allHosts
    );

  externalFolderSetMembers =
    folderSet:
    builtins.attrNames (
      lib.filterAttrs
        (_: deviceCfg: hasValue deviceCfg.id && builtins.elem folderSet (externalDeviceFolderSets deviceCfg))
        cfg.externalDevices
    );

  folderSetAttrs =
    folderSet:
    lib.mapAttrs'
      (folderId: folderCfg:
        let
          members = folderSetMembers folderSet;
          remoteMembers = lib.filter (member: member != hostname && builtins.elem member cfg.peers) members;
          externalMembers = externalFolderSetMembers folderSet;
          folderPath =
            if folderCfg ? path then
              folderCfg.path
            else
              "${cfg.syncRoot}/${folderCfg.relativePath}";
        in
        lib.nameValuePair folderId ({
          path = folderPath;
          id = folderId;
          label = folderCfg.label;
          type = "sendreceive";
          devices = remoteMembers ++ externalMembers;
          fsWatcherEnabled = true;
        } // lib.optionalAttrs (folderCfg ? ignorePerms) {
          ignorePerms = folderCfg.ignorePerms;
        } // lib.optionalAttrs (folderCfg ? ignoreDelete) {
          ignoreDelete = folderCfg.ignoreDelete;
        } // lib.optionalAttrs (folderCfg ? versioning) {
          versioning = folderCfg.versioning;
        }))
      folderCatalog.${folderSet};

  selectedFolderCatalog =
    builtins.foldl' (acc: folderSet: acc // folderCatalog.${folderSet}) { } effectiveFolderSets;

  selectedFolderAttrs =
    builtins.foldl' (acc: folderSet: acc // folderSetAttrs folderSet) { } effectiveFolderSets;

  folderRelativePathParentPrefixes =
    relativePath:
    let
      parts = lib.splitString "/" relativePath;
      parentCount = (builtins.length parts) - 1;
    in
      builtins.genList
        (idx: lib.concatStringsSep "/" (lib.take (idx + 1) parts))
        parentCount;

  selectedRelativeFolders =
    lib.filter (folderCfg: folderCfg ? relativePath) (lib.attrValues selectedFolderCatalog);

  selectedFolderRelativePaths =
    map (folderCfg: folderCfg.relativePath) selectedRelativeFolders;

  selectedAbsoluteFolders =
    lib.filter (folderCfg: folderCfg ? path) (lib.attrValues selectedFolderCatalog);

  folderRelativePathParentEntries =
    folderCfg:
    map
      (relativePath: {
        inherit relativePath;
        user = folderCfg.parentUser or cfg.user;
        group = folderCfg.parentGroup or "users";
        mode = folderCfg.parentMode or "0750";
      })
      (folderRelativePathParentPrefixes folderCfg.relativePath);

  managedSyncRootRelativeDirs =
    lib.attrValues (
      builtins.listToAttrs (
        map
          (dirCfg: lib.nameValuePair dirCfg.relativePath dirCfg)
          (lib.flatten (map folderRelativePathParentEntries selectedRelativeFolders))
      )
    );

  managedSyncRootTmpfiles =
    map
      (dirCfg: "d ${cfg.syncRoot}/${dirCfg.relativePath} ${dirCfg.mode} ${dirCfg.user} ${dirCfg.group} - -")
      managedSyncRootRelativeDirs;

  managedRelativeFolderTmpfiles =
    map
      (folderCfg: "d ${cfg.syncRoot}/${folderCfg.relativePath} ${folderCfg.mode or "0750"} ${folderCfg.user or cfg.user} ${folderCfg.group or "users"} - -")
      selectedRelativeFolders;

  managedFolderMarkerTmpfiles =
    map
      (relativePath: "d ${cfg.syncRoot}/${relativePath}/.stfolder 0755 ${cfg.user} users - -")
      selectedFolderRelativePaths;

  managedAbsoluteFolderTmpfiles =
    map
      (folderCfg: "d ${folderCfg.path} ${folderCfg.mode or "0755"} ${folderCfg.user or cfg.user} ${folderCfg.group or "users"} - -")
      selectedAbsoluteFolders;

  managedAbsoluteFolderMarkerTmpfiles =
    map
      (folderCfg: "d ${folderCfg.path}/.stfolder 0755 ${cfg.user} users - -")
      selectedAbsoluteFolders;

  managedSyncRootDirsScript =
    lib.concatMapStringsSep "\n"
      (dirCfg: ''
        install -d -m ${dirCfg.mode} -o ${dirCfg.user} -g ${dirCfg.group} "${cfg.syncRoot}/${dirCfg.relativePath}"
      '')
      managedSyncRootRelativeDirs;

  managedRelativeFolderScript =
    lib.concatMapStringsSep "\n"
      (folderCfg: ''
        install -d -m ${folderCfg.mode or "0750"} -o ${folderCfg.user or cfg.user} -g ${folderCfg.group or "users"} "${cfg.syncRoot}/${folderCfg.relativePath}"
      '')
      selectedRelativeFolders;

  managedFolderMarkerScript =
    lib.concatMapStringsSep "\n"
      (relativePath: ''
        install -d -m 0755 -o ${cfg.user} -g users "${cfg.syncRoot}/${relativePath}/.stfolder"
      '')
      selectedFolderRelativePaths;

  managedAbsoluteFolderScript =
    lib.concatMapStringsSep "\n"
      (folderCfg: ''
        install -d -m ${folderCfg.mode or "0755"} -o ${folderCfg.user or cfg.user} -g ${folderCfg.group or "users"} "${folderCfg.path}"
        install -d -m 0755 -o ${cfg.user} -g users "${folderCfg.path}/.stfolder"
      '')
      selectedAbsoluteFolders;

  selectedLinkAttrs =
    if effectiveLinkFolderSets == [ ] then
      { }
    else
      builtins.foldl' (acc: folderSet: acc // linkCatalog.${folderSet}) { } effectiveLinkFolderSets;

  selectedLinkTargets =
    lib.unique (map (linkCfg: "${cfg.syncRoot}/${linkCfg.relativePath}") (lib.attrValues selectedLinkAttrs));

  linkTargetInitScript =
    lib.concatMapStringsSep "\n"
      (target: ''mkdir -p "${target}"'')
      selectedLinkTargets;

  existingLinkDataMigrationScript =
    lib.concatStringsSep "\n"
      (
        lib.mapAttrsToList
          (relativePath: linkCfg: ''
            localPath="$HOME/${relativePath}"
            targetPath="${cfg.syncRoot}/${linkCfg.relativePath}"

            if [[ ! -L "$localPath" && -d "$localPath" ]]; then
              cp -a --no-clobber "$localPath/." "$targetPath/"
            fi
          '')
          selectedLinkAttrs
      );

  managedLinkResetScript =
    lib.concatStringsSep "\n"
      (
        lib.mapAttrsToList
          (relativePath: linkCfg: ''
            localPath="$HOME/${relativePath}"

            if [[ -L "$localPath" ]]; then
              :
            elif [[ -e "$localPath" ]]; then
              run rm -rf $VERBOSE_ARG -- "$localPath"
            fi
          '')
          selectedLinkAttrs
      );

  staleManagedLinkParents =
    lib.optionals
      (
        (selectedLinkAttrs ? "${azaharLocalSdmcBase}/title")
        || (selectedLinkAttrs ? "${azaharLocalSdmcBase}/extdata")
        || (selectedLinkAttrs ? "${azaharLocalNandBase}/extdata")
      )
      [ ".local/share/azahar-emu" ]
    ++ lib.optionals
      (
        (selectedLinkAttrs ? ".local/share/dolphin-emu/GC")
        || (selectedLinkAttrs ? ".local/share/dolphin-emu/Wii/title")
        || (selectedLinkAttrs ? ".local/share/dolphin-emu/Load/Riivolution")
      )
      [ ".local/share/dolphin-emu" ]
    ++ lib.optionals
      (
        (selectedLinkAttrs ? ".local/share/melonDS/saves")
      )
      [ ".local/share/melonDS" ]
    ++ lib.optionals
      (
        (selectedLinkAttrs ? ".local/share/eden/nand/user/save")
        || (selectedLinkAttrs ? ".local/share/eden/nand/system/save/8000000000000010")
      )
      [ ".local/share/eden" ];

  staleManagedLinkCleanupScript =
    lib.concatMapStringsSep "\n"
      (relativePath: ''
        targetPath="$HOME/${relativePath}"
        if [[ -L "$targetPath" && "$(readlink "$targetPath")" == ${builtins.storeDir}/*-home-manager-files/* ]]; then
          rm "$targetPath"
        fi
      '')
      staleManagedLinkParents;

  folderMembershipAssertions =
    lib.flatten (
      map
        (folderSet:
          map
            (memberHost: {
              assertion = memberHost == hostname || builtins.elem memberHost cfg.peers;
              message = "alanix.syncthing.folderSets includes '${folderSet}', but host '${memberHost}' is not listed in alanix.syncthing.peers.";
            })
            (folderSetMembers folderSet))
        effectiveFolderSets
    );
in
{
  options.alanix.syncthing = {
    enable = lib.mkEnableOption "declarative Syncthing on repo-managed hosts";

    user = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "User account that owns the Syncthing state and synced folders.";
    };

    deviceId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Syncthing device ID for this host.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Explicit peer hostnames for this Syncthing node.";
    };

    externalDevices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          id = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Syncthing device ID. Leave null to keep the device staged but inactive.";
          };

          addresses = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "dynamic" ];
            description = "Syncthing addresses for this non-Nix device, such as dynamic or tcp://host:22000.";
          };

          folderSets = lib.mkOption {
            type = lib.types.listOf folderSetType;
            default = [ ];
            description = "Folder sets this external device participates in.";
          };
        };
      }));
      default = { };
      description = "Non-repo-managed Syncthing devices, such as phones running Syncthing-Fork.";
    };

    syncRoot = lib.mkOption {
      type = lib.types.str;
      default = "/home/buddia/Syncthing";
      description = "Absolute path for the root Syncthing folder tree.";
    };

    listenPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "TCP listen port used by Syncthing for the selected transport.";
    };

    umask = lib.mkOption {
      type = lib.types.strMatching "[0-7]{4}";
      default = "0022";
      description = "UMask applied to the Syncthing systemd service when it creates local files and directories.";
    };

    transport = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "tailscale" ]);
      default = null;
      description = "Network transport used for Syncthing peer connectivity.";
    };

    folderSets = lib.mkOption {
      type = lib.types.listOf folderSetType;
      default = [ ];
      description = "Named folder sets enabled on this host.";
    };

    linkFolderSets = lib.mkOption {
      type = lib.types.listOf linkFolderSetType;
      default = [ ];
      description = "Named folder sets whose synced directories should be linked into local application paths for the Syncthing user.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
        {
          assertion = userAccount != null && userAccount.enable;
          message = "alanix.syncthing.user must reference an enabled alanix.users.accounts entry.";
        }
        {
          assertion = hasValue cfg.deviceId;
          message = "alanix.syncthing.deviceId must be set when alanix.syncthing.enable = true.";
        }
        {
          assertion = cfg.transport != null;
          message = "alanix.syncthing.transport must be set to \"tailscale\" when alanix.syncthing.enable = true.";
        }
        {
          assertion = transportConfig != null;
          message = "alanix.syncthing.transport must be \"tailscale\".";
        }
        {
          assertion = transportConfig == null || transportConfig.requireLocal;
          message =
            if transportConfig == null then
              "alanix.syncthing.transport must be set to \"tailscale\" when alanix.syncthing.enable = true."
            else
              transportConfig.requireLocalMessage;
        }
        {
          assertion = cfg.listenPort != null;
          message = "alanix.syncthing.listenPort must be set when alanix.syncthing.enable = true.";
        }
        {
          assertion = hasValue cfg.syncRoot && lib.hasPrefix "/" cfg.syncRoot;
          message = "alanix.syncthing.syncRoot must be an absolute path.";
        }
        {
          assertion = lib.unique cfg.peers == cfg.peers;
          message = "alanix.syncthing.peers must not contain duplicates.";
        }
        {
          assertion = lib.intersectLists cfg.peers (builtins.attrNames cfg.externalDevices) == [ ];
          message = "alanix.syncthing.peers and alanix.syncthing.externalDevices must not contain the same device name.";
        }
        {
          assertion = lib.unique cfg.folderSets == cfg.folderSets;
          message = "alanix.syncthing.folderSets must not contain duplicates.";
        }
        {
          assertion = lib.unique cfg.linkFolderSets == cfg.linkFolderSets;
          message = "alanix.syncthing.linkFolderSets must not contain duplicates.";
        }
        {
          assertion = lib.all (folderSet: builtins.elem folderSet effectiveFolderSets) effectiveLinkFolderSets;
          message = "alanix.syncthing.linkFolderSets must be a subset of alanix.syncthing.folderSets.";
        }
        {
          assertion = cfg.linkFolderSets == [ ] || userHomeReady;
          message = "alanix.syncthing.linkFolderSets requires alanix.syncthing.user to reference an enabled alanix.users.accounts entry with home.enable = true and home.directory set.";
        }
        {
          assertion = lib.hasAttrByPath [ "sops" "secrets" certSecretName ] config;
          message = "alanix.syncthing.enable requires a declared sops secret named '${certSecretName}'.";
        }
        {
          assertion = lib.hasAttrByPath [ "sops" "secrets" keySecretName ] config;
          message = "alanix.syncthing.enable requires a declared sops secret named '${keySecretName}'.";
        }
      ]
      ++ folderMembershipAssertions
      ++ lib.mapAttrsToList
        (name: deviceCfg: {
          assertion = !hasValue deviceCfg.id || deviceCfg.addresses != [ ];
          message = "alanix.syncthing.externalDevices.${name}.addresses must not be empty when id is set.";
        })
        cfg.externalDevices
      ++ map
        ({ name, hostCfg }: {
          assertion = name != hostname;
          message = "alanix.syncthing.peers must not include the current host (${hostname}).";
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = hostCfg != null;
          message = "alanix.syncthing.peers contains unknown host '${name}'.";
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = hostCfg != null && hostCfg.config.alanix.syncthing.enable;
          message = "alanix.syncthing.peers.${name} must reference a host with alanix.syncthing.enable = true.";
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = hostCfg != null && hasValue hostCfg.config.alanix.syncthing.deviceId;
          message = "alanix.syncthing.peers.${name} must reference a host with alanix.syncthing.deviceId set.";
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = hostCfg != null && hostCfg.config.alanix.syncthing.transport == cfg.transport;
          message = "alanix.syncthing.peers.${name} must use the same alanix.syncthing.transport as '${hostname}'.";
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = transportConfig != null && hostCfg != null && transportConfig.peerReady hostCfg;
          message =
            if transportConfig == null then
              "alanix.syncthing.transport must be \"tailscale\"."
            else
              transportConfig.peerMessage name;
        })
        peerHosts
      ++ map
        ({ name, hostCfg }: {
          assertion = hostCfg != null && builtins.elem hostname hostCfg.config.alanix.syncthing.peers;
          message = "alanix.syncthing.peers.${name} must also list '${hostname}' as a peer.";
        })
        peerHosts;
    }

    (lib.mkIf (transportConfig != null) {
      networking.firewall.interfaces.${transportConfig.localFirewallInterface}.allowedTCPPorts = [ cfg.listenPort ];

      system.activationScripts.alanixSyncthingPrepareManagedDirs = lib.stringAfter [ "users" ] ''
        install -d -m 0750 -o ${cfg.user} -g users "${cfg.syncRoot}"
        ${managedSyncRootDirsScript}
        ${managedRelativeFolderScript}
        ${managedFolderMarkerScript}
        ${managedAbsoluteFolderScript}
      '';

      systemd.tmpfiles.rules =
        [ "d ${cfg.syncRoot} 0750 ${cfg.user} users - -" ]
        ++ managedSyncRootTmpfiles
        ++ managedRelativeFolderTmpfiles
        ++ managedFolderMarkerTmpfiles
        ++ managedAbsoluteFolderTmpfiles
        ++ managedAbsoluteFolderMarkerTmpfiles;

      services.syncthing = {
        enable = true;
        user = cfg.user;
        group = "users";
        dataDir = userHomeDir;
        inherit configDir;
        cert = config.sops.secrets.${certSecretName}.path;
        key = config.sops.secrets.${keySecretName}.path;
        guiAddress = "127.0.0.1:8384";
        openDefaultPorts = false;
        overrideDevices = true;
        overrideFolders = true;

        settings = {
          devices =
            (builtins.listToAttrs (
              map
                ({ name, hostCfg }:
                  let
                    peerAddress = transportConfig.peerAddress hostCfg;
                    peerPort = hostCfg.config.alanix.syncthing.listenPort;
                  in
                  if !hasValue peerAddress then
                    throw "alanix.syncthing.peers.${name} is missing a usable ${cfg.transport} address."
                  else if peerPort == null then
                    throw "alanix.syncthing.peers.${name} is missing alanix.syncthing.listenPort."
                  else
                    lib.nameValuePair name {
                      inherit name;
                      id = hostCfg.config.alanix.syncthing.deviceId;
                      addresses = [ "tcp://${peerAddress}:${toString peerPort}" ];
                    })
                peerHosts
            ))
            // (lib.mapAttrs'
              (name: deviceCfg:
                lib.nameValuePair name {
                  inherit name;
                  id = deviceCfg.id;
                  addresses = deviceCfg.addresses;
                })
              activeExternalDevices);

          folders = selectedFolderAttrs;

          options = {
            listenAddresses = [ "tcp://${transportConfig.localAddress}:${toString cfg.listenPort}" ];
            localAnnounceEnabled = false;
            globalAnnounceEnabled = false;
            relaysEnabled = false;
            natEnabled = false;
            urAccepted = -1;
          };
        };
      };

      systemd.services.syncthing.serviceConfig.UMask = cfg.umask;

      systemd.services.syncthing-init = {
        # Syncthing's config reconciler talks to the local GUI API. During
        # `nixos-rebuild switch`, a hard `Requisite=` can briefly fail if
        # systemd queues this unit just before syncthing is started again.
        # A soft dependency preserves ordering without making the whole switch
        # fail on that transient race.
        wants = [ "syncthing.service" ];
        after = [ "syncthing.service" ];
        partOf = [ "syncthing.service" ];
        requisite = lib.mkForce [ ];
      };
    })

    (lib.mkIf (cfg.linkFolderSets != [ ] && userHomeReady) {
      home-manager.users.${cfg.user} = { config, lib, ... }: {
        home.activation.alanixSyncthingCleanupLegacyLinks =
          lib.hm.dag.entryBetween [ "writeBoundary" ] [ "checkFilesChanged" ] ''
            ${staleManagedLinkCleanupScript}
          '';

        home.activation.alanixSyncthingLinkTargets =
          lib.hm.dag.entryAfter [ "writeBoundary" ] linkTargetInitScript;

        home.activation.alanixSyncthingMigrateExistingLinkData =
          lib.hm.dag.entryAfter [ "alanixSyncthingLinkTargets" ] existingLinkDataMigrationScript;

        home.activation.alanixSyncthingResetManagedLinks =
          lib.hm.dag.entryBetween [ "linkGeneration" ] [ "alanixSyncthingMigrateExistingLinkData" ] ''
            ${managedLinkResetScript}
          '';

        home.file =
          lib.mapAttrs
            (_: linkCfg: {
              source = config.lib.file.mkOutOfStoreSymlink "${cfg.syncRoot}/${linkCfg.relativePath}";
              force = true;
            })
            selectedLinkAttrs;
      };
    })
  ]);
}
