# Access with http://localhost:47990
{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.sunshine;
  basePort = cfg.webUi.port - 1;
  webUiConfigured = cfg.webUi.username != null || cfg.webUi.passwordFile != null;
  webUiComplete = cfg.webUi.username != null && cfg.webUi.passwordFile != null;
  enabledAccounts = builtins.attrValues config.alanix.users.accounts;
  hasInputReadyUser = lib.any (userCfg: userCfg.enable && builtins.elem "input" userCfg.extraGroups) enabledAccounts;
  applyWebUiCreds = pkgs.writeShellScriptBin "alanix-sunshine-apply-web-ui-creds" ''
    set -euo pipefail

    password_file=${lib.escapeShellArg cfg.webUi.passwordFile}

    if [ ! -r "$password_file" ]; then
      echo "Sunshine password file is not readable: $password_file" >&2
      exit 1
    fi

    password="$(${pkgs.coreutils}/bin/tr -d '\n' < "$password_file")"

    if [ -z "$password" ]; then
      echo "Sunshine password file is empty: $password_file" >&2
      exit 1
    fi

    exec ${pkgs.sunshine}/bin/sunshine --creds ${lib.escapeShellArg cfg.webUi.username} "$password"
  '';
in
{
  options.alanix.sunshine = {
    enable = lib.mkEnableOption "Sunshine game streaming";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Sunshine should auto-start.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the firewall for Sunshine.";
    };

    capSysAdmin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Sunshine should request CAP_SYS_ADMIN.";
    };

    webUi = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 47990;
        description = "Port for the Sunshine Web UI. Sunshine's internal base port is derived as webUi.port - 1.";
      };

      username = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Declarative Sunshine Web UI username.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Readable file containing the Sunshine Web UI password in plaintext.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.desktop.enable;
        message = "alanix.sunshine: requires alanix.desktop.enable = true.";
      }
      {
        assertion = hasInputReadyUser;
        message = "alanix.sunshine: at least one enabled alanix.users.accounts entry must include \"input\" in extraGroups so Sunshine mouse/keyboard/gamepad input works.";
      }
      {
        assertion = !webUiConfigured || webUiComplete;
        message = "alanix.sunshine.webUi.username and alanix.sunshine.webUi.passwordFile must either both be set or both be null.";
      }
      {
        assertion = cfg.webUi.port >= 1025;
        message = "alanix.sunshine.webUi.port must be at least 1025 because Sunshine derives its base port as webUi.port - 1.";
      }
    ];

    boot.kernelModules = [ "uhid" ];

    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    services.sunshine = {
      enable = true;
      inherit (cfg) autoStart openFirewall capSysAdmin;
      settings.port = basePort;
    };

    systemd.user.services.sunshine.serviceConfig.ExecStartPre =
      lib.optional webUiComplete "${applyWebUiCreds}/bin/alanix-sunshine-apply-web-ui-creds";
  };
}
