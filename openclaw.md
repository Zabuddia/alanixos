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

### Patch In Local Models, Browser, Canvas, And Tailscale UI Origin

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
      ]
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
      },
      "local-llama-embeddings": {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:8082/v1",
        "apiKey": "local-llama-embeddings",
        "authHeader": false,
        "injectNumCtxForOpenAICompat": true,
        "models": [
          {
            "id": "qwen3-embedding-4b",
            "name": "qwen3-embedding-4b",
            "api": "openai-completions",
            "contextWindow": 8192,
            "input": [
              "text"
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
          "apiKey": "local-embeddings"
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

openclaw gateway start
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw dashboard --no-open
tailscale serve status
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
systemctl --user daemon-reload
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

## 3. Back On `alan-framework`

### Approve The Laptop Node In The Dashboard

```bash
openclaw dashboard --no-open
```

Open the printed local dashboard URL on `alan-framework`, then approve the pending laptop node there.

## 4. Back On `alan-laptop-nixos`

Stop the foreground node with `Ctrl+C`, then run:

```bash
systemctl --user restart openclaw-node
systemctl --user status openclaw-node --no-pager
journalctl --user -u openclaw-node -n 50 --no-pager
```

## 5. Final Checks

### On `alan-framework`

```bash
export OPENCLAW_GATEWAY_TOKEN="$(cat ~/.openclaw/gateway-token.txt)"
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw dashboard --no-open
```

### On `alan-laptop-nixos`

```bash
systemctl --user status openclaw-node --no-pager
journalctl --user -u openclaw-node -n 50 --no-pager
```

## 6. Telegram Later

On `alan-framework`:

```bash
openclaw configure --section channels
```
