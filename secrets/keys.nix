{
  editors = {
    alan-laptop-nixos = {
      recipient = "age1tzastckgekm2ynyeqexsgknyprt4p5emgw722nq3tg6a2ghgla3salq90p";
      description = "Primary editor key kept on a laptop/workstation.";
    };
  };

  hosts = {
    randy-big-nixos = {
      recipient = "age1xgpfqft6xks6qh0r29lqh2pmau6mhklqd5q8ylynmlevmemss4qsfs8tnv";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-big-nixos = {
      recipient = "age1ywa965cvxmzh39cjt2h7k4vsc7qmfqmv0dg6psalwe5td0s5j4ysycvrkd";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-framework = {
      recipient = "TODO_REPLACE_WITH_AGE_PUBKEY";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };
  };

  creationRules = [
    {
      pathRegex = "^secrets/.*\\.ya?ml$";
      editors = [ "alan-laptop-nixos" ];
      hosts = [ "randy-big-nixos" "alan-big-nixos" "alan-framework" ];
    }
  ];
}
