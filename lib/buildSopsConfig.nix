let
  flake = builtins.getFlake (toString ../.);
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
  };
  keys = import ../keys.nix;
  lib = pkgs.lib;

  resolveRecipients =
    scope: names:
    map
      (name:
        let
          recipient = lib.attrByPath [ scope name "recipient" ] null keys;
        in
        if recipient == null then
          throw "Unknown ${scope} recipient '${name}' in keys.nix"
        else
          recipient
      )
      names;

  sopsConfig = {
    creation_rules = map (rule: {
      path_regex = rule.pathRegex;
      age = lib.unique ((resolveRecipients "editors" rule.editors) ++ (resolveRecipients "hosts" rule.hosts));
    }) keys.creationRules;
  };
in
(pkgs.formats.yaml { }).generate ".sops.yaml" sopsConfig
