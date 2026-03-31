{ lib }:
let
  hasValue = value: value != null && value != "";
in
rec {
  inherit hasValue;

  wireguardAddress =
    {
      config,
      exposeCfg,
    }:
    if exposeCfg.wireguard.address != null then
      exposeCfg.wireguard.address
    else
      config.alanix.wireguard.vpnIP;

  wanPort =
    {
      exposeCfg,
    }:
    if exposeCfg.wan.port != null then
      exposeCfg.wan.port
    else if exposeCfg.wan.tls then
      443
    else
      80;

  externalPort =
    {
      exposeCfg,
      port,
    }:
    if exposeCfg.wan.enable then
      wanPort { inherit exposeCfg; }
    else if exposeCfg.wireguard.enable then
      exposeCfg.wireguard.port
    else
      port;

  httpsOnly =
    {
      exposeCfg,
    }:
    if exposeCfg.wan.enable then
      exposeCfg.wan.tls
    else if exposeCfg.wireguard.enable then
      exposeCfg.wireguard.tls
    else
      false;

  advertisedDomain =
    {
      config,
      exposeCfg,
      listenAddress,
      domainOverride ? null,
      allowWireguard ? true,
      allowListenAddressFallback ? true,
    }:
    let
      wgAddress = wireguardAddress { inherit config exposeCfg; };
    in
    if hasValue domainOverride then
      domainOverride
    else if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
      exposeCfg.wan.domain
    else if allowWireguard && exposeCfg.wireguard.enable && hasValue wgAddress then
      wgAddress
    else if allowListenAddressFallback then
      listenAddress
    else
      null;

  rootUrl =
    {
      config,
      exposeCfg,
      listenAddress,
      port,
      rootUrlOverride ? null,
      allowWireguard ? true,
      allowListenAddressFallback ? true,
    }:
    let
      wgAddress = wireguardAddress { inherit config exposeCfg; };
      publicWanPort = wanPort { inherit exposeCfg; };
    in
    if hasValue rootUrlOverride then
      rootUrlOverride
    else if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
      let
        scheme = if exposeCfg.wan.tls then "https" else "http";
        defaultPort = if exposeCfg.wan.tls then 443 else 80;
        portSuffix = if publicWanPort == defaultPort then "" else ":${toString publicWanPort}";
      in
      "${scheme}://${exposeCfg.wan.domain}${portSuffix}/"
    else if allowWireguard && exposeCfg.wireguard.enable && hasValue wgAddress then
      let
        scheme = if exposeCfg.wireguard.tls then "https" else "http";
      in
      "${scheme}://${wgAddress}:${toString exposeCfg.wireguard.port}/"
    else if allowListenAddressFallback then
      "http://${listenAddress}:${toString port}/"
    else
      null;
}
