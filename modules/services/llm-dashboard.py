#!/usr/bin/env python3

import html
import json
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    if value is None:
        value = now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def format_age(seconds: float | None) -> str:
    if seconds is None:
        return "unknown"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {remainder}s"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours}h {minutes}m"
    days, hours = divmod(hours, 24)
    return f"{days}d {hours}h"


def format_duration_ns(value: int | None) -> str:
    if value is None:
        return "unknown"
    seconds = value / 1_000_000_000
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {remainder}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m"


def format_bytes(value: int | None) -> str:
    if value is None:
        return "unknown"
    size = float(value)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    index = 0
    while size >= 1024 and index < len(units) - 1:
        size /= 1024
        index += 1
    if index == 0:
        return f"{int(size)} {units[index]}"
    return f"{size:.1f} {units[index]}"


def badge_class(kind: str) -> str:
    return {
        "good": "badge-good",
        "warn": "badge-warn",
        "bad": "badge-bad",
        "muted": "badge-muted",
        "info": "badge-info",
    }.get(kind, "badge-muted")


def normalize_lines(text: str) -> list[str]:
    return text.rstrip("\n").splitlines() if text else []


def summarize_source(service: dict) -> str:
    model = service.get("model") or {}
    if model.get("path"):
        return model["path"]
    if model.get("downloadName"):
        return f'download:{model["downloadName"]}'
    if model.get("url"):
        return model["url"]
    if model.get("hfRepo"):
        if model.get("hfFile"):
            return f'{model["hfRepo"]} :: {model["hfFile"]}'
        return model["hfRepo"]
    return "unknown"


def mmproj_summary(service: dict) -> str | None:
    model = service.get("model") or {}
    return model.get("mmprojPath") or model.get("mmprojUrl")


class Dashboard:
    def __init__(self, config_path: str) -> None:
        with open(config_path, "r", encoding="utf-8") as handle:
            self.config = json.load(handle)

        self.host_name = self.config["hostName"]
        self.backend = self.config["backend"]
        self.state_dir = self.config["stateDir"]
        self.dashboard = self.config["dashboard"]
        self.services = self.config["services"]
        self.recent_log_lines = int(self.dashboard.get("recentLogLines", 40))
        self.collect_interval = float(self.dashboard.get("collectIntervalSeconds", 5))
        self._lock = threading.Lock()
        self._state_cond = threading.Condition()
        self._state_seq = 0
        self._cached_state: dict | None = None
        self._cached_state = self.collect()
        threading.Thread(target=self._collector_loop, daemon=True).start()

    def _collector_loop(self) -> None:
        while True:
            try:
                state = self.collect()
                with self._lock:
                    self._cached_state = state
                with self._state_cond:
                    self._state_seq += 1
                    self._state_cond.notify_all()
            except Exception as exc:
                with self._lock:
                    previous = self._cached_state or {}
                    previous["collectorError"] = str(exc)
                    previous["lastUpdated"] = iso_timestamp()
                    self._cached_state = previous
                with self._state_cond:
                    self._state_seq += 1
                    self._state_cond.notify_all()
            time.sleep(self.collect_interval)

    def _run(self, args: list[str], *, timeout: int = 10) -> subprocess.CompletedProcess:
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def _systemctl_show(self, unit: str) -> dict:
        props = [
            "Id",
            "Description",
            "LoadState",
            "ActiveState",
            "SubState",
            "UnitFileState",
            "Result",
            "MainPID",
            "ExecMainPID",
            "ExecMainStartTimestampUSec",
            "ActiveEnterTimestampUSec",
            "StateChangeTimestamp",
            "StateChangeTimestampUSec",
            "NRestarts",
            "MemoryCurrent",
            "CPUUsageNSec",
            "TasksCurrent",
        ]
        proc = self._run(["systemctl", "show", unit, "--no-pager", "--property", ",".join(props)])
        if proc.returncode != 0:
            return {"error": (proc.stderr or proc.stdout or f"systemctl exited with {proc.returncode}").strip()}

        data = {}
        for line in normalize_lines(proc.stdout):
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key] = value
        return data

    def _journal_tail(self, unit: str) -> dict:
        proc = self._run(
            [
                "journalctl",
                "-u",
                unit,
                "-n",
                str(self.recent_log_lines),
                "--no-pager",
                "-o",
                "short-iso",
            ],
            timeout=15,
        )
        if proc.returncode != 0:
            return {"error": (proc.stderr or proc.stdout or f"journalctl exited with {proc.returncode}").strip()}
        return {"lines": normalize_lines(proc.stdout)}

    def _health(self, service: dict) -> dict:
        url = service["healthUrl"]
        mode = service.get("healthCheckMode", "openai-models")
        started_at = time.time()
        try:
            request = urllib.request.Request(
                url,
                method="OPTIONS" if mode == "http-options" else "GET",
            )
            with urllib.request.urlopen(request, timeout=3) as response:
                body = response.read()
            elapsed_ms = int((time.time() - started_at) * 1000)
            if mode in ("http-status", "http-options"):
                return {
                    "ok": 200 <= response.status < 300,
                    "status": response.status,
                    "elapsedMs": elapsed_ms,
                    "modelIds": [],
                }

            payload = json.loads(body.decode("utf-8"))
            model_ids = [item.get("id") for item in payload.get("data", []) if item.get("id")]
            return {
                "ok": True,
                "status": response.status,
                "elapsedMs": elapsed_ms,
                "modelIds": model_ids,
            }
        except urllib.error.HTTPError as exc:
            return {"ok": False, "error": f"HTTP {exc.code}", "elapsedMs": int((time.time() - started_at) * 1000)}
        except Exception as exc:
            return {"ok": False, "error": str(exc), "elapsedMs": int((time.time() - started_at) * 1000)}

    def _service_state(self, service: dict) -> dict:
        unit = self._systemctl_show(service["serviceName"])
        logs = self._journal_tail(service["serviceName"])
        health = self._health(service)

        start_usec = None
        for key in ("ActiveEnterTimestampUSec", "ExecMainStartTimestampUSec"):
            raw = unit.get(key)
            if raw and raw.isdigit() and int(raw) > 0:
                start_usec = int(raw)
                break

        uptime_seconds = None
        if start_usec is not None:
            uptime_seconds = time.time() - (start_usec / 1_000_000)

        active_state = unit.get("ActiveState", "unknown")
        sub_state = unit.get("SubState", "unknown")
        if active_state == "active":
            status_kind = "good"
        elif active_state in {"activating", "reloading"}:
            status_kind = "warn"
        else:
            status_kind = "bad"

        return {
            "meta": service,
            "unit": unit,
            "logs": logs,
            "health": health,
            "uptimeSeconds": uptime_seconds,
            "statusKind": status_kind,
            "activeState": active_state,
            "subState": sub_state,
        }

    def collect(self) -> dict:
        usage = shutil.disk_usage(self.state_dir)
        services = [self._service_state(service) for service in self.services]
        running = sum(1 for service in services if service["activeState"] == "active")
        unhealthy = sum(1 for service in services if not service["health"].get("ok"))
        return {
            "hostName": self.host_name,
            "backend": self.backend,
            "stateDir": self.state_dir,
            "dashboard": self.dashboard,
            "links": self.dashboard.get("links", []),
            "services": services,
            "disk": {
                "total": usage.total,
                "used": usage.used,
                "free": usage.free,
            },
            "runningServices": running,
            "unhealthyServices": unhealthy,
            "lastUpdated": iso_timestamp(),
        }

    def render_body(self, state: dict) -> str:
        services_html = "\n".join(self._render_service_card(service) for service in state["services"])
        links_html = "".join(
            f'<a class="link-pill" href="{html.escape(link["url"])}">{html.escape(link["label"])}</a>'
            for link in state.get("links", [])
        ) or '<span class="muted">No exposure links configured.</span>'

        collector_error = state.get("collectorError")
        collector_html = (
            f'<div class="banner banner-bad">Collector error: {html.escape(collector_error)}</div>'
            if collector_error
            else ""
        )

        return f"""
    {collector_html}
    <section class="hero">
      <div class="hero-top">
        <div>
          <h1>{html.escape(state["hostName"])} LLM Dashboard</h1>
          <p class="muted">Backend {html.escape(state["backend"])} · Updated <span id="updated-at">{html.escape(state["lastUpdated"])}</span></p>
        </div>
        <div class="sub-badges">
          <span class="badge badge-info" id="stream-status">live updates connected</span>
        </div>
      </div>
      <div class="metrics">
        <div class="metric">
          <span class="metric-label">State Dir</span>
          <span class="metric-value">{html.escape(state["stateDir"])}</span>
        </div>
        <div class="metric">
          <span class="metric-label">Running Services</span>
          <span class="metric-value">{state["runningServices"]} / {len(state["services"])}</span>
        </div>
        <div class="metric">
          <span class="metric-label">Unhealthy Endpoints</span>
          <span class="metric-value">{state["unhealthyServices"]}</span>
        </div>
        <div class="metric">
          <span class="metric-label">Disk Free</span>
          <span class="metric-value">{format_bytes(state["disk"]["free"])} free</span>
        </div>
        <div class="metric">
          <span class="metric-label">Disk Used</span>
          <span class="metric-value">{format_bytes(state["disk"]["used"])} / {format_bytes(state["disk"]["total"])}</span>
        </div>
      </div>
      <div>
        <p class="muted" style="margin-bottom:8px;">Exposure URLs</p>
        <div class="link-row">{links_html}</div>
      </div>
    </section>
    <section class="services">
      {services_html}
    </section>"""

    def render_html(self, state: dict) -> str:
        body_html = self.render_body(state)

        return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(self.host_name)} LLM Dashboard</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f4efe4;
      --panel: #fffaf0;
      --ink: #1f1b16;
      --muted: #6e6559;
      --line: #d8cdbb;
      --good: #185c37;
      --good-bg: #d8f1df;
      --warn: #8a5b00;
      --warn-bg: #fde8b8;
      --bad: #8f2d2d;
      --bad-bg: #f8d6d6;
      --info: #1f4f82;
      --info-bg: #dbeafe;
      --shadow: 0 12px 28px rgba(66, 44, 12, 0.08);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 24px;
      font-family: "Iosevka Aile", "IBM Plex Sans", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(241, 213, 155, 0.28), transparent 34%),
        linear-gradient(180deg, #f9f3e8 0%, var(--bg) 100%);
      color: var(--ink);
    }}
    h1, h2, h3, p {{ margin: 0; }}
    .page {{
      max-width: 1480px;
      margin: 0 auto;
      display: grid;
      gap: 18px;
    }}
    .hero, .card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 20px;
      box-shadow: var(--shadow);
    }}
    .hero {{
      padding: 24px;
      display: grid;
      gap: 18px;
    }}
    .hero-top {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: baseline;
      justify-content: space-between;
    }}
    .hero h1 {{
      font-size: clamp(2rem, 4vw, 3rem);
      line-height: 1;
      letter-spacing: -0.05em;
    }}
    .muted {{ color: var(--muted); }}
    .metrics {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
    }}
    .metric {{
      padding: 14px 16px;
      border-radius: 16px;
      background: #fff;
      border: 1px solid var(--line);
    }}
    .metric-label {{
      display: block;
      font-size: 0.85rem;
      color: var(--muted);
      margin-bottom: 6px;
    }}
    .metric-value {{
      font-weight: 700;
      font-size: 1.1rem;
    }}
    .link-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }}
    .link-pill {{
      text-decoration: none;
      color: var(--ink);
      background: #fff;
      border: 1px solid var(--line);
      padding: 8px 12px;
      border-radius: 999px;
      font-size: 0.92rem;
    }}
    .banner {{
      padding: 12px 14px;
      border-radius: 16px;
      border: 1px solid var(--line);
      font-weight: 700;
    }}
    .banner-bad {{
      background: var(--bad-bg);
      color: var(--bad);
    }}
    .services {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
      gap: 18px;
    }}
    .card {{
      padding: 18px;
      display: grid;
      gap: 14px;
    }}
    .card-head {{
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: flex-start;
    }}
    .card-head h2 {{
      font-size: 1.3rem;
      line-height: 1.1;
    }}
    .badge {{
      display: inline-flex;
      align-items: center;
      gap: 6px;
      border-radius: 999px;
      padding: 6px 10px;
      font-size: 0.82rem;
      font-weight: 700;
      white-space: nowrap;
    }}
    .badge-good {{ background: var(--good-bg); color: var(--good); }}
    .badge-warn {{ background: var(--warn-bg); color: var(--warn); }}
    .badge-bad {{ background: var(--bad-bg); color: var(--bad); }}
    .badge-muted {{ background: #ede6db; color: var(--muted); }}
    .badge-info {{ background: var(--info-bg); color: var(--info); }}
    .sub-badges {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }}
    .details {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px 14px;
    }}
    .detail {{
      min-width: 0;
    }}
    .detail-label {{
      display: block;
      font-size: 0.78rem;
      color: var(--muted);
      margin-bottom: 2px;
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }}
    .detail-value {{
      font-family: "Iosevka Fixed", "SFMono-Regular", monospace;
      font-size: 0.92rem;
      overflow-wrap: anywhere;
    }}
    .detail-value.wrap {{
      font-family: "Iosevka Aile", "IBM Plex Sans", sans-serif;
    }}
    .logs {{
      background: #171512;
      color: #f8f4eb;
      border-radius: 16px;
      padding: 12px;
      min-height: 170px;
      max-height: 320px;
      overflow: auto;
      font-family: "Iosevka Fixed", "SFMono-Regular", monospace;
      font-size: 0.82rem;
      line-height: 1.45;
      white-space: pre-wrap;
    }}
    @media (max-width: 720px) {{
      body {{ padding: 14px; }}
      .details {{ grid-template-columns: 1fr; }}
    }}
  </style>
</head>
<body>
  <div class="page" id="dashboard-root">
{body_html}
  </div>
  <script>
    (() => {{
      const root = document.getElementById("dashboard-root");
      const streamStatus = () => document.getElementById("stream-status");

      const setStatus = (text, kind) => {{
        const badge = streamStatus();
        if (!badge) return;
        badge.textContent = text;
        badge.className = `badge ${{kind}}`;
      }};

      const captureLogScroll = () => {{
        const positions = {{}};
        for (const node of document.querySelectorAll("[data-log-key]")) {{
          positions[node.dataset.logKey] = node.scrollTop;
        }}
        return positions;
      }};

      const restoreLogScroll = (positions) => {{
        for (const node of document.querySelectorAll("[data-log-key]")) {{
          const value = positions[node.dataset.logKey];
          if (typeof value === "number") {{
            node.scrollTop = value;
          }}
        }}
      }};

      const applyUpdate = (payload) => {{
        const x = window.scrollX;
        const y = window.scrollY;
        const logScroll = captureLogScroll();
        root.innerHTML = payload.html;
        window.scrollTo(x, y);
        restoreLogScroll(logScroll);
        setStatus("live updates connected", "badge badge-info");
      }};

      const connect = () => {{
        const events = new EventSource("/api/events");

        events.addEventListener("open", () => {{
          setStatus("live updates connected", "badge badge-info");
        }});

        events.addEventListener("update", (event) => {{
          const payload = JSON.parse(event.data);
          applyUpdate(payload);
        }});

        events.onerror = () => {{
          setStatus("live updates reconnecting", "badge badge-warn");
        }};
      }};

      connect();
    }})();
  </script>
</body>
</html>"""

    def _render_service_card(self, service: dict) -> str:
        meta = service["meta"]
        unit = service["unit"]
        health = service["health"]
        logs = service["logs"]
        active_badge = (
            f'<span class="badge {badge_class(service["statusKind"])}">'
            f'{html.escape(service["activeState"])} / {html.escape(service["subState"])}</span>'
        )
        health_badge = (
            f'<span class="badge {badge_class("good" if health.get("ok") else "bad")}">'
            f'health {"ok" if health.get("ok") else "down"}</span>'
        )

        model_ids = ", ".join(health.get("modelIds", [])) or "none reported"
        log_text = "\n".join(logs.get("lines", [])) if logs.get("lines") else logs.get("error", "No logs yet.")
        extra_details = []
        if meta["kind"] == "instance":
            if meta.get("runtime") == "whisper":
                extra_details.extend(
                    [
                        ("Runtime", "whisper.cpp"),
                        ("Model Alias", meta.get("alias") or "none"),
                        ("Model Name", meta.get("modelName") or "unknown"),
                        ("Model Source", summarize_source(meta)),
                        ("Download Name", (meta.get("model") or {}).get("downloadName") or "none"),
                        ("Input", ", ".join(meta.get("input", [])) or "none"),
                        ("Language", meta.get("language") or "auto"),
                        ("Translate", str(meta.get("translate"))),
                        ("Processors", str(meta.get("processors") or "1")),
                        ("Threads", str(meta.get("threads") or "auto")),
                        ("GPU", str(meta.get("gpu"))),
                        ("Convert Audio", str(meta.get("convertAudio"))),
                        ("Request Path", meta.get("requestPath") or "/"),
                        ("Inference Path", meta.get("inferencePath") or "none"),
                        ("LiteLLM", "included" if meta.get("litellmIncluded") else "not enabled"),
                        ("Extra Args", " ".join(meta.get("extraArgs", [])) or "none"),
                    ]
                )
            else:
                extra_details.extend(
                    [
                        ("Runtime", "llama.cpp"),
                        ("Model Alias", meta.get("alias") or "none"),
                        ("Model Name", meta.get("modelName") or "unknown"),
                        ("Model Source", summarize_source(meta)),
                        ("MMProj", mmproj_summary(meta) or "none"),
                        ("Input", ", ".join(meta.get("input", [])) or "none"),
                        ("Ctx / Batch", f'{meta.get("ctxSize")} / {meta.get("batchSize")} / {meta.get("ubatchSize")}'),
                        ("Parallel / GPU", f'{meta.get("parallel")} / {meta.get("gpuLayers")}'),
                        ("Threads", f'{meta.get("threads") or "auto"} / {meta.get("threadsBatch") or "auto"}'),
                        ("Flags", f'mmap={meta.get("mmap")} mlock={meta.get("mlock")} flash={meta.get("flashAttention")}'),
                        ("LiteLLM", "included" if meta.get("litellmIncluded") else "not enabled"),
                        ("Extra Args", " ".join(meta.get("extraArgs", [])) or "none"),
                    ]
                )
        else:
            extra_details.extend(
                [
                    ("Models", ", ".join(meta.get("modelAliases", [])) or "none"),
                    ("Proxy URL", meta.get("endpointUrl") or "unknown"),
                ]
            )

        base_details = [
            ("Unit", meta.get("serviceName", "unknown")),
            ("Port / Bind", f'{meta.get("port")} on {meta.get("bindHost")}'),
            ("Health URL", meta.get("healthUrl", "unknown")),
            ("Main PID", unit.get("MainPID") or "0"),
            ("Restarts", unit.get("NRestarts") or "0"),
            ("Memory", format_bytes(_parse_int(unit.get("MemoryCurrent")))),
            ("CPU", format_duration_ns(_parse_int(unit.get("CPUUsageNSec")))),
            ("Tasks", unit.get("TasksCurrent") or "unknown"),
            ("Uptime", format_age(service.get("uptimeSeconds"))),
            ("Last Models", model_ids),
            ("Health Latency", f'{health.get("elapsedMs", 0)}ms'),
            ("Health Error", health.get("error") or "none"),
        ]

        details_html = "\n".join(
            f'<div class="detail"><span class="detail-label">{html.escape(label)}</span>'
            f'<span class="detail-value {"wrap" if len(value) > 48 else ""}">{html.escape(value)}</span></div>'
            for label, value in base_details + extra_details
        )

        return f"""
<article class="card">
  <div class="card-head">
    <div>
      <h2>{html.escape(meta.get("displayName", meta.get("name", "service")))}</h2>
      <p class="muted">{html.escape(meta.get("kind", "service"))}</p>
    </div>
    <div class="sub-badges">
      {active_badge}
      {health_badge}
    </div>
  </div>
  <div class="details">
    {details_html}
  </div>
  <div>
    <h3 style="margin-bottom:8px;">Recent Logs</h3>
    <div class="logs" data-log-key="{html.escape(meta.get("serviceName", meta.get("name", "service")))}">{html.escape(log_text)}</div>
  </div>
</article>"""


def _parse_int(value: str | None) -> int | None:
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None


class RequestHandler(BaseHTTPRequestHandler):
    dashboard: Dashboard

    def respond_bytes(self, status: int, payload: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def handle_event_stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        last_sent_seq = -1

        try:
            while True:
                with self.dashboard._state_cond:
                    new_ready = self.dashboard._state_cond.wait_for(
                        lambda: (
                            self.dashboard._state_seq > last_sent_seq
                            and self.dashboard._cached_state is not None
                        ),
                        timeout=15.0,
                    )
                    if new_ready:
                        seq = self.dashboard._state_seq
                        state = self.dashboard._cached_state
                    else:
                        seq = last_sent_seq
                        state = None

                if new_ready and state is not None:
                    payload = json.dumps(
                        {
                            "updatedAt": state.get("lastUpdated") or iso_timestamp(),
                            "html": self.dashboard.render_body(state),
                        }
                    ).encode("utf-8")
                    self.wfile.write(b"event: update\n")
                    self.wfile.write(b"data: ")
                    self.wfile.write(payload)
                    self.wfile.write(b"\n\n")
                    self.wfile.flush()
                    last_sent_seq = seq
                else:
                    self.wfile.write(b"event: ping\ndata: {}\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self) -> None:
        if self.path == "/api/events":
            self.handle_event_stream()
            return

        if self.path == "/healthz":
            self.respond_bytes(200, b"ok\n", "text/plain; charset=utf-8")
            return

        if self.path not in {"/", ""}:
            self.send_error(404)
            return

        with self.dashboard._lock:
            state = self.dashboard._cached_state
        payload = self.dashboard.render_html(state or self.dashboard.collect()).encode("utf-8")
        self.respond_bytes(200, payload, "text/html; charset=utf-8")

    def log_message(self, format: str, *args) -> None:
        return


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: llm-dashboard.py <config.json>", file=sys.stderr)
        return 1

    dashboard = Dashboard(sys.argv[1])
    RequestHandler.dashboard = dashboard
    server = ThreadingHTTPServer(
        (
            dashboard.dashboard.get("listenAddress", "127.0.0.1"),
            int(dashboard.dashboard.get("port", 9843)),
        ),
        RequestHandler,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
