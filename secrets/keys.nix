{
  editors = {
    alan-laptop-nixos = {
      recipient = "age1w6a0h33yazg69vdupphhxjk3a6rdmgq5qz6c4l2d637j3grzsclqxyyl7k";
      description = "Primary editor key kept on a laptop/workstation.";
    };
    alan-framework-laptop = {
      recipient = "age16ca65fwnny3tjk890qvpmq5hu933auwzfjhzrupz50muynh7wc6q8z9n2c";
      description = "Editor key kept on a laptop/workstation.";
    };
  };

  hosts = {
    randy-big-nixos = {
      recipient = "age1xgpfqft6xks6qh0r29lqh2pmau6mhklqd5q8ylynmlevmemss4qsfs8tnv";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-big-nixos = {
      recipient = "age1fmjf2c6alaquxg558rgmrukswvfelxpq4jrr6tc8kvpe7xg07ulsa4tu7p";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-framework = {
      recipient = "age14hvqw052wzn8wlxrevzlgydthcenjc7jh4t76gwqljglknj6maash22pl5";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };
    
    alan-node = {
      recipient = "age1gvgt7lg6ledntcn3pcak6050spl8q88wjum852mjt6t984c95axq97m2wf";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-optiplex = {
      recipient = "age15dpyxhmqtehzkhatfg65yh7nwslhtdmnyz4yrrtkj2y9mdzrjdfqj9kuq5";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    alan-tv = {
      recipient = "age17hrwk6gthhga9d993c8aexnvcfzaz7jwvhf3vt8uqzeul6na8smqmunnl8";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };

    fife-tv = {
      recipient = "age1jx5wr5fq5yxgdqn9lhcgsa0y8w5fezdvu6mjzwjqxdee7lw654kshz0e9z";
      description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
    };
  };

  creationRules = [
    {
      pathRegex = "^secrets/.*\\.ya?ml$";
      editors = [ "alan-laptop-nixos" "alan-framework-laptop" ];
      hosts = [ "randy-big-nixos" "alan-big-nixos" "alan-framework" "alan-node" "alan-optiplex" "alan-tv" "fife-tv" ];
    }
  ];
}
