{ config, lib, ... }:

let
  cfg = config.alanix.desktop.fingerprint;
  fingerprintTimeout = 10;
in

lib.mkIf (config.alanix.desktop.enable && cfg.enable) {
  services.fprintd.enable = true;

  security.pam.services.swaylock.fprintAuth = true;
  security.pam.services.sudo.fprintAuth = true;

  # Without a timeout, pam_fprintd polls forever and the password fallback never
  # triggers — fingerprint is effectively forced. 10 seconds gives enough time to
  # scan, then PAM falls through to pam_unix for password entry.
  security.pam.services.swaylock.rules.auth.fprintd.settings.timeout = fingerprintTimeout;
  security.pam.services.sudo.rules.auth.fprintd.settings.timeout = fingerprintTimeout;
}
