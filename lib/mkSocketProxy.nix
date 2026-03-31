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
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${upstreamAddress}:${toString upstreamPort}";
      DynamicUser = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
