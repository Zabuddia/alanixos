{ lib }:
let
  hasValue = value: value != null && value != "";
in
rec {
  inherit hasValue;

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
    else
      port;

  httpsOnly =
    {
      exposeCfg,
    }:
    if exposeCfg.wan.enable then
      exposeCfg.wan.tls
    else
      false;

  advertisedDomain =
    {
      config,
      exposeCfg,
      listenAddress,
      domainOverride ? null,
      allowListenAddressFallback ? true,
    }:
    if hasValue domainOverride then
      domainOverride
    else if exposeCfg.wan.enable && hasValue exposeCfg.wan.domain then
      exposeCfg.wan.domain
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
      allowListenAddressFallback ? true,
    }:
    let
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
    else if allowListenAddressFallback then
      "http://${listenAddress}:${toString port}/"
    else
      null;
}
