{ pkgs }:
{
  name,
  description,
  listenAddress,
  listenPort,
  upstreamAddress,
  upstreamPort,
  bindToDevice ? null,
  freeBind ? false,
}:
let
  proxyd = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd";
  # systemd-socket-proxyd exits with error when started without socket FDs
  # (i.e. when nixos-rebuild switch restarts the unit directly instead of via
  # socket activation). Exit 0 in that case so the rebuild doesn't report a
  # failure; the socket unit will activate us normally on the next connection.
  guardedProxyd = pkgs.writeShellScript "socket-proxyd-guard" ''
    if [ "''${LISTEN_FDS:-0}" -eq 0 ]; then exit 0; fi
    exec ${proxyd} "$@"
  '';
in
{
  systemd.sockets.${name} = {
    inherit description;
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${listenAddress}:${toString listenPort}" ];
    socketConfig =
      {
        Accept = false;
      }
      // (
        if bindToDevice == null then
          {}
        else
          {
            BindToDevice = bindToDevice;
          }
      )
      // (
        if freeBind then
          {
            FreeBind = true;
          }
        else
          {}
      );
  };

  systemd.services.${name} = {
    inherit description;
    serviceConfig = {
      ExecStart = "${guardedProxyd} ${upstreamAddress}:${toString upstreamPort}";
      DynamicUser = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
