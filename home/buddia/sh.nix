{ config, pkgs, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "svcaddrs" ''
      exec /home/buddia/.nixos/scripts/show-service-addresses.sh "$@"
    '')
  ];

  programs.bash = {
    enable = true;
    initExtra = ''
      nrs() {
        local elevate
        local host
        local repo
        local system_path

        host="$(hostname -s)"
        repo="/home/buddia/.nixos"

        if command -v doas >/dev/null 2>&1; then
          elevate="doas"
        elif command -v sudo >/dev/null 2>&1; then
          elevate="sudo"
        else
          echo "nrs: need doas or sudo for activation" >&2
          return 1
        fi

        system_path="$(
          cd "$repo" && \
          nix build ".#nixosConfigurations.''${host}.config.system.build.toplevel" \
            --print-out-paths \
            --no-link \
            -L "$@"
        )" || return 1

        "$elevate" "$system_path/bin/switch-to-configuration" switch
      }

      svcaddrs() {
        local repo
        repo="/home/buddia/.nixos"
        "$repo/scripts/show-service-addresses.sh" "$@"
      }

      backupsnow() {
        local elevate

        if command -v doas >/dev/null 2>&1; then
          elevate="doas"
        elif command -v sudo >/dev/null 2>&1; then
          elevate="sudo"
        else
          echo "backupsnow: need doas or sudo to start backup services" >&2
          return 1
        fi

        "$elevate" alanix-run-backups-now "$@"
      }

      backupstatus() {
        alanix-backup-status "$@"
      }
    '';
  };
}
