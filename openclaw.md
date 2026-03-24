# OpenClaw Setup

This file is a plain runbook, not a shell script.

Run these commands as `buddia`.

Assumes:

- `node` and `npm` are already on `PATH`
- `litellm-proxy` is already running on `alan-framework`
- `http://127.0.0.1:4000/v1/models` already works

## 1. Clean Reset

Run this on any machine where you want to wipe the user-managed OpenClaw install:

```bash
systemctl --user stop openclaw-gateway.service 2>/dev/null || true
systemctl --user stop openclaw-node.service 2>/dev/null || true
systemctl --user disable openclaw-gateway.service 2>/dev/null || true
systemctl --user disable openclaw-node.service 2>/dev/null || true
systemctl --user reset-failed openclaw-gateway.service openclaw-node.service 2>/dev/null || true
rm -f ~/.config/systemd/user/openclaw-gateway.service ~/.config/systemd/user/openclaw-gateway.service.bak
rm -rf ~/.config/systemd/user/openclaw-gateway.service.d
npm uninstall -g openclaw 2>/dev/null || true
rm -f ~/.local/bin/openclaw
rm -rf ~/.local/lib/node_modules/openclaw ~/.openclaw
systemctl --user daemon-reload
```

## 2. `alan-framework`

### Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Run Interactive Onboarding

```bash
openclaw onboard --install-daemon
```

Use these choices during onboarding:

- Continue past the security warning: `Yes`
- `Setup mode`: `Manual`
- `What do you want to set up?`: `Local gateway (this machine)`
- `Workspace directory`: `/home/buddia/.openclaw/workspace`
- `Model/auth provider`: `Custom Provider`
- `API Base URL`: `http://127.0.0.1:4000/v1`
- `How do you want to provide this API key?`: `Paste API key now`
- `API Key`: `local-litellm`
- `Endpoint compatibility`: `OpenAI-compatible`
- `Model ID`: `qwen3.5-35b-a3b`
- `Endpoint ID`: `local-litellm`
- `Model alias`: `qwen3.5-35b-a3b`
- `Gateway port`: `18789`
- `Gateway bind`: `Loopback (127.0.0.1)`
- `Gateway auth`: `Token`
- `Tailscale exposure`: `Serve`
- `Reset Tailscale serve/funnel on exit?`: `No`
- `How do you want to provide the gateway token?`: `Generate/store plaintext token`
- `Configure chat channels now?`: `Yes`
- `Select a channel`: `Telegram (Bot API)`
- `Telegram bot token`: paste your real token
- `Configure DM access policies now?`: `Yes`
- `Telegram DM policy`: `Allowlist (specific users only)`
- `Telegram allowFrom`: your Telegram numeric user id
- `Web search`: choose your preferred provider
- `Configure skills now?`: `No`
- `Enable hooks?`: `Skip for now`
- `Gateway service runtime`: `Node (recommended)`
- `How do you want to hatch your bot?`: whichever you want

### Fix The LiteLLM Model Catalog

Onboarding only sets the main chat model. Run this after onboarding so chat, image, and embeddings are all correct:

```bash
jq '
  .gateway.trustedProxies = ["127.0.0.1/32", "::1/128"]
  | .gateway.controlUi.allowedOrigins = [
      "http://127.0.0.1:18789",
      "http://localhost:18789",
      "https://alan-framework.tailbb2802.ts.net"
    ]
  | .gateway.controlUi.allowInsecureAuth = true
  | .browser.enabled = true
  | .browser.defaultProfile = "openclaw"
  | .browser.headless = true
  | .browser.executablePath = "/etc/profiles/per-user/buddia/bin/chromium"
  | .tools.profile = "full"
  | if (.tools.profile | type) == "object" and .tools.profile.coding.allowlist? then
      .tools.profile.coding.allowlist |= map(select(. != "apply_patch" and . != "image_generate"))
    else . end
  | if (.tools.profiles | type) == "object" and .tools.profiles.coding.allowlist? then
      .tools.profiles.coding.allowlist |= map(select(. != "apply_patch" and . != "image_generate"))
    else . end
  | .models.providers["local-litellm"] = {
    api: "openai-completions",
    baseUrl: "http://127.0.0.1:4000/v1",
    apiKey: "local-litellm",
    authHeader: false,
    injectNumCtxForOpenAICompat: true,
    models: [
      {
        id: "qwen3.5-35b-a3b",
        name: "qwen3.5-35b-a3b",
        api: "openai-completions",
        reasoning: false,
        input: ["text"],
        contextWindow: 262144,
        maxTokens: 8192
      },
      {
        id: "qwen3-vl-30b-a3b-instruct",
        name: "qwen3-vl-30b-a3b-instruct",
        api: "openai-completions",
        reasoning: false,
        input: ["text", "image"],
        contextWindow: 32768,
        maxTokens: 8192
      },
      {
        id: "qwen3-embedding-4b",
        name: "qwen3-embedding-4b",
        api: "openai-completions",
        reasoning: false,
        input: ["text"],
        contextWindow: 8192,
        maxTokens: 8192
      }
    ]
  }
  | .agents.defaults.model.primary = "local-litellm/qwen3.5-35b-a3b"
  | .agents.defaults.imageModel.primary = "local-litellm/qwen3-vl-30b-a3b-instruct"
  | .agents.defaults.models = {
      "local-litellm/qwen3.5-35b-a3b": {
        alias: "qwen3.5-35b-a3b",
        streaming: true
      },
      "local-litellm/qwen3-vl-30b-a3b-instruct": {
        alias: "qwen3-vl-30b-a3b-instruct",
        streaming: true
      },
      "local-litellm/qwen3-embedding-4b": {
        alias: "qwen3-embedding-4b"
      }
    }
  | .agents.defaults.memorySearch = {
      enabled: true,
      provider: "openai",
      model: "qwen3-embedding-4b",
      fallback: "none",
      remote: {
        baseUrl: "http://127.0.0.1:4000/v1",
        apiKey: "local-litellm"
      }
    }
' ~/.openclaw/openclaw.json > /tmp/openclaw.json

mv /tmp/openclaw.json ~/.openclaw/openclaw.json
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
openclaw browser --browser-profile openclaw start
```

### Verify

```bash
openclaw gateway probe --token "$(openclaw config get gateway.auth.token)"
openclaw models list
openclaw models status
openclaw browser --browser-profile openclaw status
curl -fsS http://127.0.0.1:4000/v1/models | jq .
```

What you want to see:

- default model: `local-litellm/qwen3.5-35b-a3b`
- image model: `local-litellm/qwen3-vl-30b-a3b-instruct`
- configured embeddings model: `local-litellm/qwen3-embedding-4b`
- browser default profile: `openclaw`
- browser headless: `true`
- Control UI origins include local loopback and the Tailscale URL
- `gateway.controlUi.allowInsecureAuth` is `true`
- no `Proxy headers detected from untrusted address` warning for local UI traffic
- no `tailscale ENOENT` warning
- no `tools.profile (coding) allowlist contains unknown entries` warning

Note:

- `gateway.controlUi.allowInsecureAuth = true` only helps when the dashboard is opened over plain HTTP in a non-secure browser context.
- It does not bypass remote device pairing. If the browser reaches the gateway over Tailnet/Serve and shows `pairing required`, you still need to approve that browser with `openclaw devices list` and `openclaw devices approve <requestId>`.

### Gateway Logs

Live logs:

```bash
journalctl --user -fu openclaw-gateway.service
```

Recent logs once:

```bash
journalctl --user -u openclaw-gateway.service -n 200 --no-pager
```

## 3. `alan-laptop-nixos`

### Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Pair The Laptop Node

Run OpenClaw normally on the laptop and pair it to the framework gateway using the tokenized dashboard URL or normal node flow.

If you want the old simple foreground flow:

```bash
openclaw node run \
  --host alan-framework.tailbb2802.ts.net \
  --port 443 \
  --tls \
  --display-name alan-laptop-nixos
```

## 4. Notes

- `imageModel` works with the LiteLLM vision model.
- `tools.media` pre-digest media-understanding still does not work with `local-litellm` in the current OpenClaw version.
- If you see media-understanding errors, that is separate from normal image-model routing.
