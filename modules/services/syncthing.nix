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
    if cfg.transport == "wireguard" then
      {
        localAddress = config.alanix.wireguard.vpnIP;
        localFirewallInterface = "wg0";
        requireLocal = config.alanix.wireguard.enable && hasValue config.alanix.wireguard.vpnIP;
        requireLocalMessage = "alanix.syncthing.transport = \"wireguard\" requires alanix.wireguard.enable = true and alanix.wireguard.vpnIP to be set.";
        peerAddress = hostCfg: hostCfg.config.alanix.wireguard.vpnIP;
        peerReady = hostCfg: hostCfg.config.alanix.wireguard.enable && hasValue hostCfg.config.alanix.wireguard.vpnIP;
        peerMessage = peerName: "alanix.syncthing.peers.${peerName} must reference a host with alanix.wireguard.enable = true and alanix.wireguard.vpnIP set when transport = \"wireguard\".";
      }
    else if cfg.transport == "tailscale" then
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

  emulationFolders = {
    "games-azahar-emu" = {
      label = "games/azahar-emu";
      relativePath = "games/azahar-emu";
    };
    "games-dolphin-emu-gc" = {
      label = "games/dolphin-emu/GC";
      relativePath = "games/dolphin-emu/GC";
    };
    "games-dolphin-emu-wii-title" = {
      label = "games/dolphin-emu/Wii/title";
      relativePath = "games/dolphin-emu/Wii/title";
    };
    "games-melonds-saves" = {
      label = "games/melonDS/saves";
      relativePath = "games/melonDS/saves";
    };
    "games-ryujinx" = {
      label = "games/Ryujinx";
      relativePath = "games/Ryujinx";
    };
  };

  folderCatalog = {
    emulation = emulationFolders;
  };

  emulationLinks = {
    ".local/share/azahar-emu" = {
      relativePath = "games/azahar-emu";
    };
    ".local/share/dolphin-emu/GC" = {
      relativePath = "games/dolphin-emu/GC";
    };
    ".local/share/dolphin-emu/Wii/title" = {
      relativePath = "games/dolphin-emu/Wii/title";
    };
    ".local/share/melonDS/saves" = {
      relativePath = "games/melonDS/saves";
    };
    ".config/Ryujinx/bis/user/save" = {
      relativePath = "games/Ryujinx";
    };
  };

  linkCatalog = {
    emulation = emulationLinks;
  };

  folderSetMembers =
    folderSet:
    builtins.attrNames (
      lib.filterAttrs
        (_: hostCfg:
          hostCfg.config.alanix.syncthing.enable
          && builtins.elem folderSet hostCfg.config.alanix.syncthing.folderSets
        )
        allHosts
    );

  folderSetAttrs =
    folderSet:
    lib.mapAttrs'
      (folderId: folderCfg:
        let
          members = folderSetMembers folderSet;
          remoteMembers = lib.filter (member: member != hostname && builtins.elem member cfg.peers) members;
        in
        lib.nameValuePair folderId {
          path = "${cfg.syncRoot}/${folderCfg.relativePath}";
          id = folderId;
          label = folderCfg.label;
          type = "sendreceive";
          devices = remoteMembers;
          fsWatcherEnabled = true;
        })
      folderCatalog.${folderSet};

  selectedFolderAttrs =
    if cfg.folderSets == [ ] then
      { }
    else
      lib.mkMerge (map folderSetAttrs cfg.folderSets);

  emulationTmpfiles =
    lib.mapAttrsToList
      (_: folderCfg: "d ${cfg.syncRoot}/${folderCfg.relativePath} 0750 ${cfg.user} users - -")
      emulationFolders;

  selectedLinkAttrs =
    if cfg.linkFolderSets == [ ] then
      { }
    else
      builtins.foldl' (acc: folderSet: acc // linkCatalog.${folderSet}) { } cfg.linkFolderSets;

  selectedLinkTargets =
    lib.unique (map (linkCfg: "${cfg.syncRoot}/${linkCfg.relativePath}") (lib.attrValues selectedLinkAttrs));

  linkTargetInitScript =
    lib.concatMapStringsSep "\n" (target: ''mkdir -p "${target}"'') selectedLinkTargets;

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
        cfg.folderSets
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

    transport = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "wireguard" "tailscale" ]);
      default = null;
      description = "Network transport used for Syncthing peer connectivity.";
    };

    folderSets = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "emulation" ]);
      default = [ ];
      description = "Named folder sets enabled on this host.";
    };

    linkFolderSets = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "emulation" ]);
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
          message = "alanix.syncthing.transport must be set to either \"wireguard\" or \"tailscale\" when alanix.syncthing.enable = true.";
        }
        {
          assertion = transportConfig != null;
          message = "alanix.syncthing.transport must be one of: wireguard, tailscale.";
        }
        {
          assertion = transportConfig == null || transportConfig.requireLocal;
          message =
            if transportConfig == null then
              "alanix.syncthing.transport must be set to either \"wireguard\" or \"tailscale\" when alanix.syncthing.enable = true."
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
          assertion = lib.unique cfg.folderSets == cfg.folderSets;
          message = "alanix.syncthing.folderSets must not contain duplicates.";
        }
        {
          assertion = lib.unique cfg.linkFolderSets == cfg.linkFolderSets;
          message = "alanix.syncthing.linkFolderSets must not contain duplicates.";
        }
        {
          assertion = lib.all (folderSet: builtins.elem folderSet cfg.folderSets) cfg.linkFolderSets;
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
              "alanix.syncthing.transport must be one of: wireguard, tailscale."
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

      systemd.tmpfiles.rules =
        [ "d ${cfg.syncRoot} 0750 ${cfg.user} users - -" ]
        ++ lib.optionals (builtins.elem "emulation" cfg.folderSets) (
          [ "d ${cfg.syncRoot}/games 0750 ${cfg.user} users - -" ]
          ++ emulationTmpfiles
        );

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
          devices = builtins.listToAttrs (
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
          );

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
    })

    (lib.mkIf (cfg.linkFolderSets != [ ] && userHomeReady) {
      home-manager.users.${cfg.user} = { config, lib, ... }: {
        home.activation.alanixSyncthingLinkTargets =
          lib.hm.dag.entryAfter [ "writeBoundary" ] linkTargetInitScript;

        home.file =
          lib.mapAttrs
            (_: linkCfg: {
              source = config.lib.file.mkOutOfStoreSymlink "${cfg.syncRoot}/${linkCfg.relativePath}";
              recursive = true;
              force = true;
            })
            selectedLinkAttrs;
      };
    })
  ]);
}
