# alanixos

# SOPS
```
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
mkdir -p ~/.config/sops/age
sudo cp /var/lib/sops-nix/key.txt ~/.config/sops/age/keys.txt
sudo chown -R $USER:$(id -gn) ~/.config/sops
chmod 0600 ~/.config/sops/age/keys.txt
```