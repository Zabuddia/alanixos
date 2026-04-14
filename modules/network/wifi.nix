{ lib, config, ... }:

let
  cfg = config.alanix.wifi;
  networks = cfg.networks;
  indexed = lib.imap0 (i: n: { inherit i; inherit (n) ssid pskSecret; }) networks;
  toVar = i: "WIFI_PSK_${toString i}";
in
{
  options.alanix.wifi = {
    networks = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          ssid = lib.mkOption {
            type = lib.types.str;
            description = "WiFi network SSID.";
          };

          pskSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of the sops secret containing the WPA2 PSK.";
          };
        };
      });
      default = [ ];
      description = "Declarative WiFi networks. Credentials are stored in sops secrets and applied via NetworkManager.";
    };
  };

  config = lib.mkIf (networks != [ ]) {
    sops.templates."alanix-wifi-env" = {
      content = lib.concatMapStrings (x:
        "${toVar x.i}=${config.sops.placeholder.${x.pskSecret}}\n"
      ) indexed;
      owner = "root";
      mode = "0400";
    };

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.templates."alanix-wifi-env".path ];
      profiles = lib.listToAttrs (map (x:
        lib.nameValuePair x.ssid {
          connection = { id = x.ssid; type = "wifi"; };
          wifi = { mode = "infrastructure"; ssid = x.ssid; };
          wifi-security = { auth-alg = "open"; key-mgmt = "wpa-psk"; psk = "$" + (toVar x.i); };
          ipv4 = { method = "auto"; };
          ipv6 = { addr-gen-mode = "stable-privacy"; method = "auto"; };
        }
      ) indexed);
    };
  };
}
