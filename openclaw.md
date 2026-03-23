# OpenClaw Commands

This file is a plain runbook, not a shell script.

Run these commands as `buddia`.

Assumes:

- you already rebuilt both machines
- you already opened a new shell after that rebuild

If you want a truly clean first-time setup, run this before the first OpenClaw command on a machine:

```bash
rm -rf ~/.openclaw
```

## 1. `alan-framework`

### Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Create Gateway Config

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

### Patch In Local Chat, Vision, Memory Embeddings, Browser, Canvas, And Tailscale UI Origin

Chat and vision are configured under `models.providers` plus `agents.defaults.model` / `agents.defaults.imageModel`.

Embeddings are configured separately under `agents.defaults.memorySearch` and point directly at the local embeddings endpoint, so there is no separate embeddings entry under `models.providers`.

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

### Install And Start Gateway Service

```bash
openclaw gateway install \
  --force \
  --runtime node \
  --port 18789 \
  --token "$OPENCLAW_GATEWAY_TOKEN"
```

```bash
export OPENCLAW_GATEWAY_TOKEN="$(cat ~/.openclaw/gateway-token.txt)"

systemctl --user daemon-reload
openclaw gateway start
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw dashboard --no-open
tailscale serve status
```

If you later upgrade OpenClaw itself, rewrite the user service entrypoint before updating plugins:

```bash
export OPENCLAW_GATEWAY_TOKEN="$(cat ~/.openclaw/gateway-token.txt)"

openclaw doctor
openclaw gateway install \
  --force \
  --runtime node \
  --port 18789 \
  --token "$OPENCLAW_GATEWAY_TOKEN"
systemctl --user daemon-reload
openclaw gateway restart
```

### Verify Local Models

```bash
curl -fsS http://127.0.0.1:8080/v1/models | jq .
curl -fsS http://127.0.0.1:8081/v1/models | jq .
curl -fsS http://127.0.0.1:8082/v1/models | jq .
```

## 2. `alan-laptop-nixos`

### Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Set The Gateway Token For First Pairing

Use the same token generated on `alan-framework`.

```bash
export OPENCLAW_GATEWAY_TOKEN='paste-the-token-from-alan-framework-here'
```

### Start The Laptop Node In The Foreground

```bash
openclaw node run \
  --host alan-framework.tailbb2802.ts.net \
  --port 443 \
  --tls \
  --display-name alan-laptop-nixos
```

Leave that running.

If the first run says `pairing required`, approve the laptop in the framework dashboard, then run the same `openclaw node run ...` command again.

## 3. Back On `alan-framework`

### Approve The Laptop Node In The Dashboard

```bash
openclaw dashboard --no-open
```

Open the printed local dashboard URL on `alan-framework`, then approve the pending laptop node there.

## 4. Leave The Framework Dashboard Bootstrap On For Now

Do not remove `gateway.controlUi.dangerouslyDisableDeviceAuth` yet.

## 5. Stop The Laptop Node

When you want the laptop node off, press `Ctrl+C` in the foreground `openclaw node run ...` terminal.

## 6. Final Checks

### On `alan-framework`

```bash
export OPENCLAW_GATEWAY_TOKEN="$(cat ~/.openclaw/gateway-token.txt)"
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw dashboard --no-open
```

### On `alan-laptop-nixos`

```bash
pgrep -af 'openclaw node run'
```

## 7. Telegram Later

Do this on `alan-framework`.

### Add The Bot Token And Enable Telegram

```bash
export TELEGRAM_BOT_TOKEN='paste-your-bot-token-here'
```

### Set A Durable Telegram Allowlist

Replace the example numeric IDs with the real Telegram user IDs you want to allow.

```bash
export TELEGRAM_ALLOWLIST='["123456789", "987654321"]'
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

### Verify

```bash
journalctl --user -u openclaw-gateway.service -n 100 --no-pager | grep -Ei 'telegram|grammy|bot'
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
```

### Optional: If You Really Want DM Pairing Instead

Leave `dmPolicy: "pairing"` instead of switching to `allowlist`, DM the bot, then approve the pairing in the framework dashboard.

## 8. Nostr Later

Do this on `alan-framework`.

### Install The Plugin And Trust Only The Installed Nostr Extension

```bash
openclaw plugins install @openclaw/nostr
rm -rf ~/.local/lib/node_modules/openclaw/extensions/nostr
[ -e ~/.openclaw/extensions/shared ] || ln -s ~/.local/lib/node_modules/openclaw/extensions/shared ~/.openclaw/extensions/shared
jq '
  .plugins = ((.plugins // {}) + {
    allow: (((.plugins.allow // []) + ["nostr"]) | unique)
  })
' ~/.openclaw/openclaw.json > /tmp/openclaw.json
mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

If you later install more non-bundled plugins, add their ids to `plugins.allow` too.

### Add The Nostr Channel

Use an existing Nostr private key in `nsec...` or 64-char hex format.

If you need to generate one first:

```bash
nak key generate
```

`nak key generate` returns a 64-char hex private key.

To derive the hex public key from a hex private key:

```bash
nak key public '<your-hex-private-key>'
```

If your private key is in `nsec...` form, decode it to hex first:

```bash
nak key public "$(nak decode '<your-nsec-private-key>')"
```

If you need the `npub...` form for allowlists:

```bash
nak encode npub "$(nak key public "$(nak decode '<your-nsec-private-key>')")"
```

```bash
export NOSTR_PRIVATE_KEY='paste-your-nsec-here'
```

```bash
openclaw channels add --channel nostr --private-key "$NOSTR_PRIVATE_KEY"
systemctl --user restart openclaw-gateway.service
```

### Optional: Set Explicit Relay URLs

```bash
openclaw channels add \
  --channel nostr \
  --private-key "$NOSTR_PRIVATE_KEY" \
  --relay-urls "wss://relay.damus.io,wss://relay.primal.net"
systemctl --user restart openclaw-gateway.service
```

### Optional: Keep The Private Key In The Environment

If you want the key in the environment instead of storing it in `~/.openclaw/openclaw.json`:

```bash
openclaw channels add --channel nostr --private-key "$NOSTR_PRIVATE_KEY" --use-env
systemctl --user restart openclaw-gateway.service
```

### Optional: Allow Only Your Own Nostr Account

Replace `npub1...` with your own Nostr public key if you want immediate access without DM pairing.

```bash
jq '
  .channels.nostr.dmPolicy = "allowlist"
  | .channels.nostr.allowFrom = ["npub1..."]
' ~/.openclaw/openclaw.json > /tmp/openclaw.json
mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user restart openclaw-gateway.service
```

### If You Keep Default DM Pairing

`pairing` is the default Nostr DM policy. DM the bot from your Nostr client, wait for the pairing code, then approve it on `alan-framework`:

```bash
openclaw pairing list --channel nostr
openclaw pairing approve --channel nostr <CODE>
```

### Verify

```bash
journalctl --user -u openclaw-gateway.service -n 100 --no-pager | grep -Ei 'nostr'
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
```
