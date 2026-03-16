{
  editors = {
    alan-laptop-nixos = {
      recipient = "age1w6a0h33yazg69vdupphhxjk3a6rdmgq5qz6c4l2d637j3grzsclqxyyl7k";
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
      recipient = "age14hvqw052wzn8wlxrevzlgydthcenjc7jh4t76gwqljglknj6maash22pl5";
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
