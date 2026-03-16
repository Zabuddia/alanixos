{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    extensions = with pkgs.vscode-extensions; [
      anthropic.claude-code
      saoudrizwan.claude-dev
      ms-vscode-remote.remote-ssh
      jnoortheen.nix-ide
    ];
  };
}
