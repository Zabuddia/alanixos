# Service Catalog

This is the declarative map of the operator's personal services. It describes
where a capability belongs; current runtime state must still be checked before
claiming that a service is available.

## Control and home automation

- `alan-framework`: OpenClaw gateway, LiteLLM, local text and multimodal Qwen
  models, embedding model, speech transcription, and the default command and
  browser execution environment.
- `alan-home`: Home Assistant, MQTT broker, Assist configuration, and the
  OpenClaw conversation integration. Home Assistant is the authority for
  physical devices, entity state, routines, notifications, and media-player
  service calls.
- `alan-framework`: Wyoming Whisper and Piper endpoints consumed by Home
  Assistant over the private Tailscale network.

## Desktop computers

The known desktop targets are `alan-big-nixos`, `alan-framework`,
`alan-framework-laptop`, `alan-home`, `alan-node`, `alan-optiplex`, `alan-tv`,
`fife-tv`, and `randy-big-nixos`. Each exposes the local, allow-listed
`alanix-desktop-control` command over the operator's existing SSH access. It can
inspect or capture the current Sway session, read or write the text clipboard,
launch an installed desktop application, and close the focused window. It is
not a network service and does not accept arbitrary shell commands.

## Cluster-managed personal services

The following services fail over among `alan-big-nixos`, `alan-optiplex`, and
`randy-big-nixos`. Do not assume that one member is the current owner; query the
cluster controller or the stable service endpoint when the active host matters.

- Communication and groupware: the `fifefin.com` mail service, Roundcube,
  Radicale Calendar/Contacts, and XMPP/Prosody. Nextcloud is deployed but is
  intentionally not an OpenClaw data source or tool target.
- Files and personal knowledge: File Browser, Syncthing, and Immich. OpenClaw's
  personal-files root is the `buddia` File Browser folder replicated to
  `alan-framework` by Syncthing. Do not use Nextcloud for files or knowledge.
- Media: Jellyfin, Navidrome, Audiobookshelf, Kavita, and Invidious.
- Personal data: Actual Budget, Grocy, Homebox, and Vaultwarden.
- Development and research: Forgejo, SearXNG, and Open WebUI.
- Network services: Headscale/Headplane, AdGuard Home, OwnTracks, and the
  cluster dashboard.

Stable browser endpoints use the corresponding `fifefin.com` service name,
such as `radicale.fifefin.com`, `forgejo.fifefin.com`, and
`jellyfin.fifefin.com`. Prefer the declarative commands in `TOOLS.md` over
browser automation for these services.

## Media and television

- `alan-tv`: primary Kodi playback target. Kodi provides movies and live TV;
  Home Assistant controls the application and ordinary playback, while the
  focused `kodi-control` wrapper accepts Jellyfin, Navidrome, Audiobookshelf,
  Invidious, and live-TV playback handoffs from OpenClaw.
- Jellyfin supplies movies, shows, recordings, and videos. Navidrome supplies
  music through its Kodi add-on; `alan-tv` does not synchronize or index the
  music folder locally. Audiobookshelf supplies audiobooks, and Kavita supplies
  ebooks.
- TVHeadend is deployed on `fife-tv` and `randy-big-nixos`. The HDHomeRun at the
  configured LAN endpoint supplies live television to Jellyfin.

## Bitcoin

- `alan-node`: bitcoind, Fulcrum, and the mempool frontend. OpenClaw's
  `bitcoin-read` command exposes only blockchain, network, transaction, mempool,
  wallet-list, and wallet-balance reads. It has no signing, sending, wallet
  creation, address generation, or raw RPC passthrough operation.

## Capability boundaries

- Browser automation uses a dedicated OpenClaw Chromium profile, not the
  operator's everyday browser profile.
- OpenClaw has declarative account-backed access to Radicale, Forgejo,
  Jellyfin, Navidrome, and Audiobookshelf. It has no Nextcloud integration and
  must not use Nextcloud as a fallback.
- Mail, XMPP, maps, Immich, and the remaining catalog services are inventory
  only until a tool and credentials are explicitly configured.
- Git repositories and NixOS hosts can already be inspected through the local
  filesystem or SSH. Repository mutations, rebuild activation, messages, and
  other external effects remain governed by `POLICY.md`.
