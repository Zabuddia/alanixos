# OpenClaw Setup

This file is a plain runbook, not a shell script.

Run these commands as `buddia`.

Assumes:

- you already rebuilt both machines
- you already opened a new shell after that rebuild

## 1. Clean Reset

Run this on any machine you want to wipe before starting over:

```bash
systemctl --user stop openclaw-gateway.service 2>/dev/null || true
systemctl --user stop openclaw-node.service 2>/dev/null || true
systemctl --user disable openclaw-gateway.service 2>/dev/null || true
systemctl --user reset-failed openclaw-gateway.service openclaw-node.service 2>/dev/null || true
rm -f ~/.config/systemd/user/openclaw-gateway.service ~/.config/systemd/user/openclaw-gateway.service.bak
rm -rf ~/.config/systemd/user/openclaw-gateway.service.d
npm uninstall -g openclaw 2>/dev/null || true
rm -rf ~/.openclaw ~/.local/bin/openclaw ~/.local/lib/node_modules/openclaw
systemctl --user daemon-reload
```

## 2. `alan-framework`

### Install And Onboard

```bash
npm install -g openclaw@latest
```

```bash
export OPENCLAW_GATEWAY_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
```

```bash
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --mode local \
  --flow manual \
  --auth-choice skip \
  --gateway-auth token \
  --gateway-token "$OPENCLAW_GATEWAY_TOKEN" \
  --gateway-bind loopback \
  --gateway-port 18789 \
  --tailscale serve \
  --no-install-daemon \
  --skip-channels \
  --skip-search \
  --skip-skills \
  --skip-ui \
  --skip-health
```

```bash
printf '%s\n' "$OPENCLAW_GATEWAY_TOKEN" > ~/.openclaw/gateway-token.txt
chmod 600 ~/.openclaw/gateway-token.txt
```

### Patch Config

```bash
cat > /tmp/openclaw-framework.patch.json <<EOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "allowTailscale": true
    },
    "http": {
      "endpoints": {
        "responses": {
          "enabled": true
        },
        "chatCompletions": {
          "enabled": true
        }
      }
    },
    "controlUi": {
      "allowedOrigins": [
        "http://127.0.0.1:18789",
        "http://localhost:18789",
        "https://alan-framework.tailbb2802.ts.net"
      ],
      "dangerouslyDisableDeviceAuth": true
    },
    "trustedProxies": [
      "127.0.0.1/32",
      "::1/128"
    ],
    "tailscale": {
      "mode": "serve"
    }
  },
  "discovery": {
    "mdns": {
      "mode": "minimal"
    }
  },
  "models": {
    "providers": {
      "local-llama-chat": {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:8080/v1",
        "apiKey": "local-llama-chat",
        "authHeader": false,
        "injectNumCtxForOpenAICompat": true,
        "models": [
          {
            "id": "qwen3.5-35b-a3b",
            "name": "qwen3.5-35b-a3b",
            "api": "openai-completions",
            "contextWindow": 262144,
            "input": [
              "text"
            ]
          }
        ]
      },
      "local-llama-vision": {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:8081/v1",
        "apiKey": "local-llama-vision",
        "authHeader": false,
        "injectNumCtxForOpenAICompat": true,
        "models": [
          {
            "id": "qwen3-vl-30b-a3b-instruct",
            "name": "qwen3-vl-30b-a3b-instruct",
            "api": "openai-completions",
            "contextWindow": 32768,
            "input": [
              "text",
              "image"
            ]
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "local-llama-chat/qwen3.5-35b-a3b"
      },
      "imageModel": {
        "primary": "local-llama-vision/qwen3-vl-30b-a3b-instruct"
      },
      "models": {
        "local-llama-chat/qwen3.5-35b-a3b": {
          "alias": "qwen3.5-35b-a3b",
          "streaming": true
        },
        "local-llama-vision/qwen3-vl-30b-a3b-instruct": {
          "alias": "qwen3-vl-30b-a3b-instruct",
          "streaming": true
        }
      },
      "memorySearch": {
        "enabled": true,
        "provider": "openai",
        "model": "qwen3-embedding-4b",
        "fallback": "none",
        "remote": {
          "baseUrl": "http://127.0.0.1:8082/v1",
          "apiKey": "local-llama-embeddings"
        }
      }
    }
  },
  "browser": {
    "enabled": true,
    "evaluateEnabled": true,
    "headless": false,
    "executablePath": "$(command -v chromium)"
  },
  "canvasHost": {
    "enabled": true
  }
}
EOF
```

```bash
jq -s '.[0] * .[1]' ~/.openclaw/openclaw.json /tmp/openclaw-framework.patch.json > /tmp/openclaw-framework.json
mv /tmp/openclaw-framework.json ~/.openclaw/openclaw.json
rm /tmp/openclaw-framework.patch.json
```

### Install And Start The Gateway

This writes the user-level systemd service for the local OpenClaw gateway.

```bash
openclaw gateway install \
  --force \
  --runtime node \
  --port 18789 \
  --token "$OPENCLAW_GATEWAY_TOKEN"
```

Reload systemd so it sees the new user service definition:

```bash
systemctl --user daemon-reload
```

Start or restart the gateway service:

```bash
openclaw gateway start
```

Print the local dashboard URL. You will use this on `alan-framework` to approve devices:

```bash
openclaw dashboard --no-open
```

Reload the saved token into the shell, then approve the local CLI as an operator device. This is the one-time step that lets the CLI manage the gateway cleanly on the same machine:

```bash
export OPENCLAW_GATEWAY_TOKEN="$(cat ~/.openclaw/gateway-token.txt)"
openclaw devices approve --latest
```

Verify that the gateway is reachable with the shared token:

```bash
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
```

Confirm Tailscale Serve is exposing the gateway path you expect:

```bash
tailscale serve status
```

### Check Local Model Endpoints

```bash
curl -fsS http://127.0.0.1:8080/v1/models | jq .
curl -fsS http://127.0.0.1:8081/v1/models | jq .
curl -fsS http://127.0.0.1:8082/v1/models | jq .
```

## 3. `alan-laptop-nixos`

### Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Pair The Laptop Node

Use the same token generated on `alan-framework`.

```bash
export OPENCLAW_GATEWAY_TOKEN='paste-the-token-from-alan-framework-here'
```

```bash
openclaw node run \
  --host alan-framework.tailbb2802.ts.net \
  --port 443 \
  --tls \
  --display-name alan-laptop-nixos
```

Leave that terminal running.

## 4. Back On `alan-framework`

### Approve The Laptop Node

```bash
openclaw dashboard --no-open
```

Open the printed dashboard URL on `alan-framework`, then approve the pending laptop node.

## 5. Telegram

Do this on `alan-framework`.

```bash
export TELEGRAM_BOT_TOKEN='paste-your-bot-token-here'
export TELEGRAM_ALLOWLIST='["5255330939", "7336229793"]'
```

```bash
jq --arg token "$TELEGRAM_BOT_TOKEN" --argjson allowlist "$TELEGRAM_ALLOWLIST" '
  .channels.telegram = ((.channels.telegram // {}) + {
    enabled: true,
    botToken: $token,
    dmPolicy: "allowlist",
    allowFrom: $allowlist,
    groupPolicy: "allowlist",
    groupAllowFrom: $allowlist,
    groups: {
      "*": {
        requireMention: true
      }
    }
  })
' ~/.openclaw/openclaw.json > /tmp/openclaw.json
mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

## 6. Nostr

Do this on `alan-framework`.

Nostr is optional. It lets OpenClaw receive and reply to encrypted Nostr DMs.

Defaults:

- private key can be `nsec...` or 64-char hex
- DM policy defaults to `pairing`
- default relays are fine unless you want different ones

### Install The Plugin

```bash
openclaw plugins install @openclaw/nostr
```

```bash
jq '
  .plugins = ((.plugins // {}) + {
    allow: (((.plugins.allow // []) + ["nostr"]) | unique)
  })
' ~/.openclaw/openclaw.json > /tmp/openclaw.json
mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

### Add The Channel

If you need a key first, generate one:

```bash
nak key generate
```

Then set the private key and add the channel:

```bash
export NOSTR_PRIVATE_KEY='paste-your-nsec-or-hex-private-key-here'
```

```bash
openclaw channels add --channel nostr --private-key "$NOSTR_PRIVATE_KEY" --use-env
systemctl --user restart openclaw-gateway.service
```

### Optional: Custom Relays

```bash
openclaw channels add \
  --channel nostr \
  --private-key "$NOSTR_PRIVATE_KEY" \
  --relay-urls "wss://relay.damus.io,wss://relay.primal.net" \
  --use-env
systemctl --user restart openclaw-gateway.service
```

### Optional: Allow Only Your Own Nostr Account

If you want to skip DM pairing and only allow your own account, use your `npub...` here:

```bash
jq '
  .channels.nostr.dmPolicy = "allowlist"
  | .channels.nostr.allowFrom = ["npub1..."]
' ~/.openclaw/openclaw.json > /tmp/openclaw.json
mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

If you need your public key from an `nsec...` key:

```bash
nak encode npub "$(nak key public "$(nak decode "$NOSTR_PRIVATE_KEY")")"
```

### Pairing

If you keep the default Nostr DM pairing flow:

```bash
openclaw pairing list --channel nostr
openclaw pairing approve --channel nostr <CODE>
```

### Verify

```bash
journalctl --user -u openclaw-gateway.service -n 100 --no-pager | grep -Ei 'nostr|relay'
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
```


b47290e9785230c1123c2893f51aac4c2b18129277b3c8996f9c636285f7fab1

│
◇  Telegram DM access warning ──────────────────────────────────────────────╮
│                                                                           │
│  Your bot is using DM policy: pairing.                                    │
│  Any Telegram user who discovers the bot can send pairing requests.       │
│  For private use, configure an allowlist with your Telegram user id:      │
│    openclaw config set channels.telegram.dmPolicy "allowlist"             │
│    openclaw config set channels.telegram.allowFrom '["YOUR_USER_ID"]'     │
│  Docs: channels/pairing  │
│                                                                           │
├───────────────────────────────────────────────────────────────────────────╯