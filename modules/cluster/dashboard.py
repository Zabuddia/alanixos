#!/usr/bin/env python3

import glob
import html
import json
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def parse_duration_seconds(value: str) -> float:
    if value.endswith("ms"):
        return int(value[:-2]) / 1000.0
    if value.endswith("s"):
        return float(value[:-1])
    if value.endswith("m"):
        return float(value[:-1]) * 60.0
    raise ValueError(f"unsupported duration: {value}")


def decode_etcd_string(value: str) -> str:
    import base64

    try:
        decoded = base64.b64decode(value, validate=True).decode("utf-8")
        if decoded and all(ch.isprintable() or ch.isspace() for ch in decoded):
            return decoded
    except Exception:
        pass
    return value


def parse_lease_id(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 10)
        except ValueError:
            return int(value, 16)
    raise ValueError(f"unsupported lease id type: {type(value)!r}")


def summarize_error(message: str, *, limit: int = 400) -> str:
    flattened = " ".join(message.split())
    if len(flattened) <= limit:
        return flattened
    return flattened[: limit - 3] + "..."


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


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


def parse_completed_at(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def badge_class(kind: str) -> str:
    return {
        "good": "badge-good",
        "warn": "badge-warn",
        "bad": "badge-bad",
        "muted": "badge-muted",
        "info": "badge-info",
    }.get(kind, "badge-muted")


class Dashboard:
    def __init__(self, config_path: str) -> None:
        with open(config_path, "r", encoding="utf-8") as handle:
            self.config = json.load(handle)

        self.cluster = self.config["cluster"]
        self.services = self.config.get("services", {})
        self.dashboard = self.config.get("dashboard", {})
        self.hostname = self.cluster["hostname"]
        self.leader_key = self.cluster["leaderKey"]
        self.target = self.cluster["activeTarget"]
        self.endpoints = self.cluster["endpoints"]
        self.members = self.cluster["priority"]
        self.bootstrap_host = self.cluster["bootstrapHost"]
        self.recent_events = int(self.dashboard.get("recentEvents", 40))

    def run(self, cmd: list[str], *, timeout: float = 5.0, check: bool = True) -> subprocess.CompletedProcess[str]:
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                text=True,
                capture_output=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or ""
            stderr = exc.stderr or ""
            raise RuntimeError(
                f"timed out after {timeout}s: {' '.join(shlex.quote(part) for part in cmd)}\n"
                f"stdout:\n{stdout}\n"
                f"stderr:\n{stderr}"
            ) from exc

        if check and proc.returncode != 0:
            raise RuntimeError(
                f"command failed ({proc.returncode}): {' '.join(shlex.quote(part) for part in cmd)}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            )
        return proc

    def etcdctl(self, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        cmd = ["etcdctl", f"--endpoints={','.join(self.endpoints)}", "--write-out=json"] + args
        return self.run(cmd, check=check)

    def get_leader(self) -> dict:
        try:
            proc = self.etcdctl(["get", self.leader_key], check=False)
        except Exception as exc:
            return {
                "present": False,
                "error": summarize_error(str(exc)),
            }

        if proc.returncode != 0:
            return {
                "present": False,
                "error": summarize_error(proc.stderr or proc.stdout or "failed to query leader"),
            }

        try:
            payload = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError as exc:
            return {
                "present": False,
                "error": summarize_error(f"invalid etcd response: {exc}"),
            }

        kvs = payload.get("kvs", [])
        if not kvs:
            return {"present": False}

        kv = kvs[0]
        return {
            "present": True,
            "host": decode_etcd_string(kv["value"]),
            "leaseId": parse_lease_id(kv.get("lease")),
            "createRevision": int(kv["create_revision"]),
            "modRevision": int(kv["mod_revision"]),
        }

    def unit_status(self, unit: str) -> dict:
        properties = ["LoadState", "ActiveState", "SubState", "UnitFileState", "Description"]
        try:
            proc = self.run(
                ["systemctl", "show", unit, f"--property={','.join(properties)}"],
                timeout=3.0,
                check=False,
            )
        except Exception as exc:
            return {"name": unit, "error": summarize_error(str(exc))}

        if proc.returncode != 0:
            return {
                "name": unit,
                "error": summarize_error(proc.stderr or proc.stdout or f"failed to inspect {unit}"),
            }

        data = {"name": unit}
        for line in proc.stdout.splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key] = value
        return data

    def managed_units(self) -> list[str]:
        units = ["alanix-cluster-controller.service", self.target]
        if "http://127.0.0.1:2379" in self.endpoints:
            units.append("etcd.service")
        for service in self.services.values():
            units.extend(service.get("activeUnits", []))
        seen = set()
        ordered = []
        for unit in units:
            if unit not in seen:
                ordered.append(unit)
                seen.add(unit)
        return ordered

    def workload_units(self) -> list[str]:
        units = [self.target]
        for service in self.services.values():
            units.extend(service.get("activeUnits", []))
        seen = set()
        ordered = []
        for unit in units:
            if unit not in seen:
                ordered.append(unit)
                seen.add(unit)
        return ordered

    def any_workload_active(self, unit_statuses: dict[str, dict]) -> bool:
        return any(
            unit_statuses[unit].get("ActiveState") == "active"
            for unit in self.workload_units()
            if unit in unit_statuses
        )

    def manifest_state(self, service_name: str, service: dict) -> dict:
        manifests = []
        for path in glob.glob(service["localManifestGlob"]):
            manifest_path = Path(path)
            if not manifest_path.exists():
                continue
            try:
                payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue

            completed_at = parse_completed_at(payload.get("completedAt"))
            age_seconds = None
            if completed_at is not None:
                age_seconds = (now_utc() - completed_at).total_seconds()
            max_age_seconds = parse_duration_seconds(service["maxBackupAge"])
            fresh = age_seconds is not None and age_seconds <= max_age_seconds
            manifests.append(
                {
                    "path": str(manifest_path),
                    "service": payload.get("service"),
                    "sourceHost": payload.get("sourceHost"),
                    "leaderRevision": payload.get("leaderRevision"),
                    "completedAt": payload.get("completedAt"),
                    "snapshotId": payload.get("snapshotId"),
                    "repoPath": payload.get("repoPath"),
                    "ageSeconds": age_seconds,
                    "ageHuman": format_age(age_seconds),
                    "fresh": fresh,
                }
            )

        manifests.sort(key=lambda item: item.get("completedAt") or "", reverse=True)
        freshest = manifests[0] if manifests else None

        if freshest and freshest["fresh"]:
            readiness = {"ready": True, "reason": "fresh-backup"}
        elif freshest:
            readiness = {"ready": False, "reason": "stale-backup"}
        elif self.hostname == self.bootstrap_host:
            readiness = {"ready": True, "reason": "bootstrap-host"}
        else:
            readiness = {"ready": False, "reason": "no-local-backup"}

        return {
            "freshestManifest": freshest,
            "manifests": manifests,
            "promotionReadiness": readiness,
            "remoteTargets": [target["host"] for target in service.get("remoteTargets", [])],
            "backupInterval": service["backupInterval"],
            "maxBackupAge": service["maxBackupAge"],
            "activeUnits": service.get("activeUnits", []),
        }

    def recent_controller_events(self) -> list[str]:
        try:
            proc = self.run(
                [
                    "journalctl",
                    "-u",
                    "alanix-cluster-controller",
                    "-b",
                    "-n",
                    str(self.recent_events * 3),
                    "--no-pager",
                    "-o",
                    "short-iso",
                ],
                timeout=5.0,
                check=False,
            )
        except Exception as exc:
            return [f"failed to read journal: {summarize_error(str(exc))}"]

        if proc.returncode != 0:
            return [summarize_error(proc.stderr or proc.stdout or "failed to read controller journal")]

        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        filtered = [
            line
            for line in lines
            if "[alanix-cluster]" in line
            or "Started Alanix cluster controller." in line
            or "Stopped Alanix cluster controller." in line
            or "Stopping Alanix cluster controller..." in line
        ]
        if filtered:
            return filtered[-self.recent_events :]
        return lines[-self.recent_events :]

    def collect(self) -> dict:
        timestamp = now_utc().replace(microsecond=0).isoformat().replace("+00:00", "Z")
        leader = self.get_leader()
        unit_statuses = {unit: self.unit_status(unit) for unit in self.managed_units()}
        any_active = self.any_workload_active(unit_statuses)
        target_active = unit_statuses.get(self.target, {}).get("ActiveState") == "active"

        if leader.get("error"):
            role = {"label": "unknown", "kind": "warn"}
        elif leader.get("present"):
            if leader.get("host") == self.hostname:
                role = {"label": "leader" if target_active else "leader-recovering", "kind": "good"}
            elif any_active:
                role = {"label": "conflict", "kind": "bad"}
            else:
                role = {"label": "follower", "kind": "info"}
        else:
            role = {"label": "waiting-for-leader" if not any_active else "lease-missing-active", "kind": "warn"}

        services = {
            service_name: self.manifest_state(service_name, service)
            for service_name, service in self.services.items()
        }

        members = [
            {
                "host": host,
                "priorityIndex": index,
                "isLocal": host == self.hostname,
                "isLeader": leader.get("present") and leader.get("host") == host,
            }
            for index, host in enumerate(self.members)
        ]

        return {
            "generatedAt": timestamp,
            "hostname": self.hostname,
            "cluster": {
                "name": self.cluster["name"],
                "transport": self.cluster["transport"],
                "members": members,
                "leader": leader,
                "role": role,
                "activeTarget": self.target,
            },
            "units": unit_statuses,
            "services": services,
            "recentEvents": self.recent_controller_events(),
        }

    def render_html(self, state: dict) -> str:
        leader = state["cluster"]["leader"]
        role = state["cluster"]["role"]
        units = state["units"]
        services = state["services"]

        leader_summary = "none"
        if leader.get("error"):
            leader_summary = f"error: {leader['error']}"
        elif leader.get("present"):
            leader_summary = leader["host"]

        member_chips = "".join(
            (
                f'<span class="chip {"chip-local" if member["isLocal"] else ""} {"chip-leader" if member["isLeader"] else ""}">'
                f'#{member["priorityIndex"] + 1} {html.escape(member["host"])}'
                f"</span>"
            )
            for member in state["cluster"]["members"]
        )

        unit_rows = []
        for unit_name, unit in units.items():
            status_text = unit.get("ActiveState", unit.get("error", "unknown"))
            kind = "good" if unit.get("ActiveState") == "active" else "warn"
            if unit.get("ActiveState") in { "failed", "inactive" }:
                kind = "bad" if unit.get("ActiveState") == "failed" else "muted"
            if unit.get("error"):
                kind = "bad"
            unit_rows.append(
                "<tr>"
                f"<td>{html.escape(unit_name)}</td>"
                f"<td><span class='badge {badge_class(kind)}'>{html.escape(status_text)}</span></td>"
                f"<td>{html.escape(unit.get('SubState', ''))}</td>"
                f"<td>{html.escape(unit.get('UnitFileState', ''))}</td>"
                "</tr>"
            )

        service_sections = []
        for service_name, service in services.items():
            readiness = service["promotionReadiness"]
            readiness_kind = "good" if readiness["ready"] else "warn"
            freshest = service["freshestManifest"]
            manifests = service["manifests"]
            freshest_html = "<span class='muted'>No local manifest</span>"
            if freshest is not None:
                freshest_html = (
                    f"<strong>{html.escape(freshest.get('sourceHost') or 'unknown')}</strong> "
                    f"<span class='muted'>snapshot {html.escape(freshest.get('snapshotId') or 'unknown')}</span><br>"
                    f"<span class='muted'>{html.escape(freshest.get('completedAt') or 'unknown')} · "
                    f"{html.escape(freshest.get('ageHuman') or 'unknown')} old</span>"
                )

            manifest_rows = []
            for manifest in manifests[:5]:
                manifest_rows.append(
                    "<tr>"
                    f"<td>{html.escape(manifest.get('sourceHost') or 'unknown')}</td>"
                    f"<td>{html.escape(manifest.get('snapshotId') or 'unknown')}</td>"
                    f"<td>{html.escape(manifest.get('completedAt') or 'unknown')}</td>"
                    f"<td><span class='badge {badge_class('good' if manifest.get('fresh') else 'warn')}'>{'fresh' if manifest.get('fresh') else 'stale'}</span></td>"
                    "</tr>"
                )
            manifests_table = (
                "<table><thead><tr><th>Source</th><th>Snapshot</th><th>Completed</th><th>Fresh</th></tr></thead>"
                f"<tbody>{''.join(manifest_rows) if manifest_rows else '<tr><td colspan=\"4\" class=\"muted\">No local manifests</td></tr>'}</tbody></table>"
            )

            active_units = "".join(
                f"<span class='chip'>{html.escape(unit)}</span>" for unit in service["activeUnits"]
            ) or "<span class='muted'>None</span>"
            remote_targets = "".join(
                f"<span class='chip'>{html.escape(host)}</span>" for host in service["remoteTargets"]
            ) or "<span class='muted'>None</span>"

            service_sections.append(
                "<section class='service-card'>"
                f"<h3>{html.escape(service_name)}</h3>"
                "<div class='service-meta'>"
                f"<span class='badge {badge_class(readiness_kind)}'>{html.escape(readiness['reason'])}</span>"
                f"<span class='muted'>backup every {html.escape(service['backupInterval'])}</span>"
                f"<span class='muted'>max age {html.escape(service['maxBackupAge'])}</span>"
                "</div>"
                f"<div class='manifest-summary'>{freshest_html}</div>"
                "<div class='chip-row'>"
                f"{active_units}"
                "</div>"
                "<div class='chip-row'>"
                f"{remote_targets}"
                "</div>"
                f"{manifests_table}"
                "</section>"
            )

        events_html = "\n".join(html.escape(line) for line in state["recentEvents"])
        raw_json = html.escape(json.dumps(state, indent=2))

        return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="10">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Alanix Cluster Dashboard · {html.escape(self.hostname)}</title>
    <style>
      :root {{
        --bg: #f6f1e8;
        --panel: #fffdf8;
        --line: #d9ccb8;
        --text: #1d241b;
        --muted: #5f6c62;
        --good: #2f7a45;
        --warn: #b56b18;
        --bad: #a3362a;
        --info: #245f8d;
        --accent: #24452d;
      }}
      * {{ box-sizing: border-box; }}
      body {{
        margin: 0;
        font-family: "Iosevka Aile", "IBM Plex Sans", "Segoe UI", sans-serif;
        color: var(--text);
        background:
          radial-gradient(circle at top right, rgba(36, 69, 45, 0.10), transparent 28rem),
          linear-gradient(180deg, #fbf7f0, var(--bg));
      }}
      main {{
        max-width: 78rem;
        margin: 0 auto;
        padding: 1.5rem;
      }}
      h1, h2, h3 {{
        margin: 0;
        font-weight: 700;
        letter-spacing: -0.02em;
      }}
      h1 {{
        font-size: 2rem;
      }}
      h2 {{
        font-size: 1.1rem;
        margin-bottom: 0.75rem;
      }}
      .hero {{
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        align-items: end;
        margin-bottom: 1.25rem;
      }}
      .hero p {{
        margin: 0.4rem 0 0;
        color: var(--muted);
      }}
      .grid {{
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr));
        gap: 0.9rem;
        margin-bottom: 1.25rem;
      }}
      .panel, .service-card {{
        background: rgba(255, 253, 248, 0.92);
        border: 1px solid var(--line);
        border-radius: 1rem;
        padding: 1rem;
        box-shadow: 0 0.6rem 1.8rem rgba(54, 43, 22, 0.06);
      }}
      .metric-label {{
        display: block;
        font-size: 0.82rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--muted);
        margin-bottom: 0.45rem;
      }}
      .metric-value {{
        font-size: 1.3rem;
        font-weight: 700;
      }}
      .badge, .chip {{
        display: inline-flex;
        align-items: center;
        gap: 0.25rem;
        border-radius: 999px;
        padding: 0.2rem 0.55rem;
        font-size: 0.82rem;
        line-height: 1.4;
      }}
      .badge-good {{ background: rgba(47, 122, 69, 0.12); color: var(--good); }}
      .badge-warn {{ background: rgba(181, 107, 24, 0.12); color: var(--warn); }}
      .badge-bad {{ background: rgba(163, 54, 42, 0.12); color: var(--bad); }}
      .badge-muted {{ background: rgba(95, 108, 98, 0.12); color: var(--muted); }}
      .badge-info {{ background: rgba(36, 95, 141, 0.12); color: var(--info); }}
      .chip {{
        background: rgba(36, 69, 45, 0.08);
        color: var(--accent);
        margin: 0 0.35rem 0.35rem 0;
      }}
      .chip-local {{
        border: 1px solid rgba(36, 69, 45, 0.26);
      }}
      .chip-leader {{
        background: rgba(47, 122, 69, 0.15);
        color: var(--good);
      }}
      .section {{
        margin-bottom: 1.25rem;
      }}
      .members {{
        margin-top: 0.85rem;
      }}
      table {{
        width: 100%;
        border-collapse: collapse;
        margin-top: 0.85rem;
      }}
      th, td {{
        padding: 0.55rem 0.4rem;
        text-align: left;
        border-top: 1px solid rgba(217, 204, 184, 0.7);
        vertical-align: top;
      }}
      th {{
        color: var(--muted);
        font-size: 0.85rem;
        font-weight: 600;
      }}
      .services {{
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(21rem, 1fr));
        gap: 1rem;
      }}
      .service-card h3 {{
        margin-bottom: 0.35rem;
      }}
      .service-meta {{
        display: flex;
        flex-wrap: wrap;
        gap: 0.45rem;
        margin-bottom: 0.8rem;
      }}
      .manifest-summary {{
        margin-bottom: 0.75rem;
      }}
      .chip-row {{
        margin-bottom: 0.6rem;
      }}
      pre {{
        margin: 0;
        padding: 1rem;
        background: #1a211a;
        color: #eef5ec;
        border-radius: 1rem;
        overflow: auto;
        font-family: "Iosevka Term", "IBM Plex Mono", monospace;
        font-size: 0.88rem;
      }}
      .muted {{
        color: var(--muted);
      }}
      details {{
        margin-top: 1rem;
      }}
      summary {{
        cursor: pointer;
        color: var(--accent);
        font-weight: 600;
      }}
      @media (max-width: 700px) {{
        .hero {{
          flex-direction: column;
          align-items: start;
        }}
      }}
    </style>
  </head>
  <body>
    <main>
      <section class="hero">
        <div>
          <h1>Alanix Cluster Dashboard</h1>
          <p>{html.escape(self.hostname)} · cluster {html.escape(state["cluster"]["name"])} · refreshed {html.escape(state["generatedAt"])}</p>
        </div>
        <div>
          <span class="badge {badge_class(role['kind'])}">{html.escape(role['label'])}</span>
        </div>
      </section>

      <section class="grid">
        <article class="panel">
          <span class="metric-label">Leader</span>
          <div class="metric-value">{html.escape(leader_summary)}</div>
        </article>
        <article class="panel">
          <span class="metric-label">Controller</span>
          <div class="metric-value">{html.escape(units["alanix-cluster-controller.service"].get("ActiveState", units["alanix-cluster-controller.service"].get("error", "unknown")))}</div>
        </article>
        <article class="panel">
          <span class="metric-label">etcd</span>
          <div class="metric-value">{html.escape(units.get("etcd.service", {}).get("ActiveState", "n/a"))}</div>
        </article>
        <article class="panel">
          <span class="metric-label">Active Target</span>
          <div class="metric-value">{html.escape(units[self.target].get("ActiveState", units[self.target].get("error", "unknown")))}</div>
        </article>
      </section>

      <section class="panel section">
        <h2>Members</h2>
        <div class="members">{member_chips}</div>
      </section>

      <section class="panel section">
        <h2>Unit Status</h2>
        <table>
          <thead>
            <tr>
              <th>Unit</th>
              <th>Active</th>
              <th>Substate</th>
              <th>Enabled</th>
            </tr>
          </thead>
          <tbody>
            {''.join(unit_rows)}
          </tbody>
        </table>
      </section>

      <section class="section">
        <h2>Services</h2>
        <div class="services">
          {''.join(service_sections) if service_sections else '<div class="panel muted">No clustered services configured yet.</div>'}
        </div>
      </section>

      <section class="section">
        <h2>Recent Events</h2>
        <pre>{events_html}</pre>
      </section>

      <section class="section">
        <details>
          <summary>Raw JSON</summary>
          <pre>{raw_json}</pre>
        </details>
      </section>
    </main>
  </body>
</html>
"""


class RequestHandler(BaseHTTPRequestHandler):
    dashboard: Dashboard

    def do_GET(self) -> None:  # noqa: N802
        state = self.dashboard.collect()
        if self.path == "/api/status":
            payload = json.dumps(state, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path in {"/", ""}:
            payload = self.dashboard.render_html(state).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path == "/healthz":
            payload = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: dashboard.py <config.json>", file=sys.stderr)
        raise SystemExit(2)

    config_path = sys.argv[1]
    dashboard = Dashboard(config_path)
    listen_address = dashboard.dashboard.get("listenAddress", "127.0.0.1")
    listen_port = int(dashboard.dashboard.get("port", 9842))

    RequestHandler.dashboard = dashboard
    server = ThreadingHTTPServer((listen_address, listen_port), RequestHandler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
