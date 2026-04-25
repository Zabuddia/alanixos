#!/usr/bin/env python3

import glob
import html
import hashlib
import http.cookies
import json
import os
import secrets
import shlex
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
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
    if value.endswith("h"):
        return float(value[:-1]) * 60.0 * 60.0
    if value.endswith("d"):
        return float(value[:-1]) * 60.0 * 60.0 * 24.0
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


def unique_links(links: list[dict]) -> list[dict]:
    seen = set()
    unique = []
    for link in links:
        key = link.get("url")
        if not key or key in seen:
            continue
        seen.add(key)
        unique.append(link)
    return unique


def build_url(*, scheme: str, host: str, port: int, path: str = "/") -> str:
    default_port = 443 if scheme == "https" else 80
    port_suffix = "" if port == default_port else f":{port}"
    return f"{scheme}://{host}{port_suffix}{path}"


def format_bytes(value: int | float | None) -> str:
    if value is None:
        return "unknown"
    size = float(value)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit_index = 0
    while size >= 1024.0 and unit_index < len(units) - 1:
        size /= 1024.0
        unit_index += 1
    if unit_index == 0:
        return f"{int(size)} {units[unit_index]}"
    return f"{size:.1f} {units[unit_index]}"


def manifest_pin_id(manifest_path: str) -> str:
    return hashlib.sha256(manifest_path.encode("utf-8")).hexdigest()


def atomic_write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}")
    try:
        temp_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)



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
        self.runtime_dir = Path(os.environ.get("ALANIX_CLUSTER_RUNTIME_DIR", "/run/alanix-cluster"))
        self.admin_queue_dir = self.runtime_dir / "admin-queue"
        self.runtime_state_file = self.runtime_dir / "controller-state.json"
        self.cluster_data_dir = Path(self.cluster["backup"]["repoBaseDir"]) / self.cluster["name"]
        self.admin = self.dashboard.get("admin", {})
        admin_toggle = self.admin.get("enable")
        if admin_toggle is None:
            admin_toggle = self.admin.get("enabled")
        self.admin_enabled = bool(admin_toggle) and bool(self.admin.get("hashedPasswordFile"))
        self.admin_username = self.admin.get("username") or "buddia"
        self.admin_password_file = self.admin.get("hashedPasswordFile")
        self.admin_session_ttl = parse_duration_seconds(self.admin.get("sessionTtl", "12h"))
        self.sessions = {}
        self.sessions_lock = threading.Lock()

    def run(
        self,
        cmd: list[str],
        *,
        timeout: float = 5.0,
        check: bool = True,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                text=True,
                input=input_text,
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

    def verify_password(self, username: str, password: str) -> bool:
        if not self.admin_enabled:
            return False
        if username != self.admin_username or not self.admin_password_file:
            return False

        for hashed in self.password_hash_candidates(username):
            try:
                proc = self.run(
                    ["mkpasswd", "-S", hashed, "-s"],
                    timeout=5.0,
                    check=False,
                    input_text=password + "\n",
                )
            except Exception:
                continue
            if proc.returncode == 0 and secrets.compare_digest(proc.stdout.strip(), hashed):
                return True
        return False

    def password_hash_candidates(self, username: str) -> list[str]:
        candidates = []

        getent_path = shutil.which("getent")
        if not getent_path:
            fallback_getent = Path("/run/current-system/sw/bin/getent")
            if fallback_getent.exists():
                getent_path = str(fallback_getent)

        if getent_path:
            try:
                proc = self.run([getent_path, "shadow", username], timeout=5.0, check=False)
            except Exception:
                proc = None
            if proc is not None and proc.returncode == 0:
                parts = proc.stdout.strip().split(":")
                if len(parts) >= 2:
                    shadow_hash = parts[1].strip()
                    if shadow_hash and shadow_hash not in {"!", "*", "x"}:
                        candidates.append(shadow_hash)

        if self.admin_password_file:
            try:
                hashed = Path(self.admin_password_file).read_text(encoding="utf-8").strip()
            except OSError:
                hashed = ""
            if hashed and hashed not in {"!", "*", "x"} and hashed not in candidates:
                candidates.append(hashed)

        return candidates

    def create_session(self, username: str) -> dict:
        session_id = secrets.token_urlsafe(32)
        session = {
            "id": session_id,
            "username": username,
            "csrfToken": secrets.token_urlsafe(24),
            "createdAt": time.time(),
            "expiresAt": time.time() + self.admin_session_ttl,
        }
        with self.sessions_lock:
            self.sessions[session_id] = session
        return session

    def cleanup_sessions(self) -> None:
        now = time.time()
        with self.sessions_lock:
            expired = [session_id for session_id, session in self.sessions.items() if session["expiresAt"] <= now]
            for session_id in expired:
                self.sessions.pop(session_id, None)

    def session_from_cookie(self, cookie_header: str | None):
        if not cookie_header:
            return None
        self.cleanup_sessions()
        cookie = http.cookies.SimpleCookie()
        try:
            cookie.load(cookie_header)
        except http.cookies.CookieError:
            return None
        morsel = cookie.get("alanix_cluster_session")
        if morsel is None:
            return None
        session_id = morsel.value
        with self.sessions_lock:
            session = self.sessions.get(session_id)
            if session is None:
                return None
            if session["expiresAt"] <= time.time():
                self.sessions.pop(session_id, None)
                return None
            session["expiresAt"] = time.time() + self.admin_session_ttl
            return dict(session)

    def destroy_session(self, session_id: str | None) -> None:
        if not session_id:
            return
        with self.sessions_lock:
            self.sessions.pop(session_id, None)

    def queue_admin_request(self, payload: dict) -> None:
        request_id = payload.get("id") or f"{int(time.time())}-{secrets.token_hex(6)}"
        request = dict(payload)
        request["id"] = request_id
        request.setdefault("submittedAt", iso_timestamp())
        path = self.admin_queue_dir / f"{request_id}.json"
        atomic_write_json(path, request)

    def controller_runtime_state(self) -> dict:
        if not self.runtime_state_file.exists():
            return {}
        try:
            return json.loads(self.runtime_state_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def queued_admin_requests(self) -> list[dict]:
        requests = []
        for path in sorted(self.admin_queue_dir.glob("*.json")):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            payload["_path"] = str(path)
            requests.append(payload)
        return requests

    def service_pin_record(self, service_name: str, manifest_path: str) -> dict | None:
        pin_path = self.cluster_data_dir / service_name / "pins" / f"{manifest_pin_id(manifest_path)}.json"
        if not pin_path.exists():
            return None
        try:
            return json.loads(pin_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return None

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

    def runtime_tor_link(self, service_name: str, service: dict) -> dict | None:
        tor_cfg = service.get("tor") or {}
        if not tor_cfg.get("enabled"):
            return None

        state_dir_name = tor_cfg.get("stateDirName") or service_name
        hostname = None
        hostname_paths = [
            Path("/var/lib/alanix-cluster/tor-hostnames") / state_dir_name,
            Path("/var/lib/tor/alanix-cluster") / state_dir_name / "hostname",
        ]

        for hostname_path in hostname_paths:
            if not hostname_path.exists():
                continue
            try:
                candidate = hostname_path.read_text(encoding="utf-8").strip()
            except OSError:
                continue
            if candidate:
                hostname = candidate
                break

        if not hostname:
            return None

        scheme = "https" if tor_cfg.get("tls") else "http"
        port = int(tor_cfg.get("publicPort") or (443 if scheme == "https" else 80))
        service_label = service.get("label") or service_name.title()
        return {
            "url": build_url(scheme=scheme, host=hostname, port=port),
            "label": f"{service_label} (tor)",
            "transport": "tor",
        }

    def manifest_state(self, service_name: str, service: dict) -> dict:
        recovery_mode = service.get("recoveryMode", "backup")
        service_label = service.get("label") or service_name.title()
        if recovery_mode == "declarative":
            result = {
                "freshestManifest": None,
                "manifests": [],
                "promotionReadiness": {"ready": True, "reason": "declarative"},
                "remoteTargets": [target["host"] for target in service.get("remoteTargets", [])],
                "backupInterval": service.get("backupInterval"),
                "maxBackupAge": service.get("maxBackupAge"),
                "activeUnits": service.get("activeUnits", []),
                "recoveryMode": recovery_mode,
                "recoveryDescription": service.get("recoveryDescription", "declarative configuration"),
            }

            tor_url = service.get("torUrl") or None
            if tor_url:
                result["torLink"] = {
                    "url": tor_url,
                    "label": f"{service_label} (tor)",
                    "transport": "tor",
                }
            else:
                tor_link = self.runtime_tor_link(service_name, service)
                if tor_link:
                    result["torLink"] = tor_link

            return result

        manifests = []
        manifest_globs = service.get("localManifestGlobs") or [service["localManifestGlob"]]
        seen = set()
        for manifest_glob in manifest_globs:
            for path in glob.glob(manifest_glob):
                manifest_path = Path(path)
                if not manifest_path.exists():
                    continue
                manifest_key = str(manifest_path)
                if manifest_key in seen:
                    continue
                seen.add(manifest_key)
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
                pin = self.service_pin_record(service_name, str(manifest_path))
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
                        "imported": bool(payload.get("imported")),
                        "note": payload.get("note") or "",
                        "requestedBy": payload.get("requestedBy"),
                        "pinned": pin is not None,
                        "pinNote": (pin or {}).get("note", ""),
                        "pinRequestedBy": (pin or {}).get("requestedBy"),
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

        result = {
            "freshestManifest": freshest,
            "manifests": manifests,
            "promotionReadiness": readiness,
            "remoteTargets": [target["host"] for target in service.get("remoteTargets", [])],
            "backupInterval": service["backupInterval"],
            "maxBackupAge": service["maxBackupAge"],
            "activeUnits": service.get("activeUnits", []),
            "recoveryMode": recovery_mode,
        }

        tor_url = service.get("torUrl") or None
        if tor_url:
            result["torLink"] = {
                "url": tor_url,
                "label": f"{service_label} (tor)",
                "transport": "tor",
            }
        else:
            tor_link = self.runtime_tor_link(service_name, service)
            if tor_link:
                result["torLink"] = tor_link

        return result

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
        controller_state = self.controller_runtime_state()
        queued_admin_requests = self.queued_admin_requests()

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
        service_operations = controller_state.get("serviceOperations") or {}
        for service_name, service_state in services.items():
            service_state["currentOperation"] = service_operations.get(service_name)
        leader_host = leader.get("host") if leader.get("present") else None
        is_leader = role["label"] in {"leader", "leader-recovering"}
        for service_name, service_state in services.items():
            links_by_host = self.services[service_name].get("linksByHost", {})
            tor_link = service_state.pop("torLink", None)
            active_links = unique_links(links_by_host.get(leader_host, [])) if leader_host else []
            # Tor links are stable regardless of which host holds the lease — always show them.
            if tor_link:
                active_links = unique_links(active_links + [tor_link])
            service_state["activeLinks"] = active_links
            # On the leader the service is actively running here — "stale-backup" is
            # misleading since promotion readiness doesn't apply to the running node.
            if is_leader:
                service_state["promotionReadiness"] = {"ready": True, "reason": "active"}

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
            "dashboardLinks": unique_links(self.dashboard.get("links", [])),
            "units": unit_statuses,
            "services": services,
            "controllerState": controller_state,
            "adminQueue": queued_admin_requests,
            "adminConfig": {
                "enabled": self.admin_enabled,
                "username": self.admin_username,
            },
            "recentEvents": self.recent_controller_events(),
        }

    def render_html(self, state: dict, *, session: dict | None = None, login_error: str | None = None) -> str:
        leader = state["cluster"]["leader"]
        role = state["cluster"]["role"]
        units = state["units"]
        services = state["services"]
        dashboard_links = state.get("dashboardLinks", [])
        controller_state = state.get("controllerState") or {}
        admin_queue = state.get("adminQueue") or []
        admin_enabled = bool(state.get("adminConfig", {}).get("enabled"))
        is_admin = session is not None and admin_enabled

        leader_summary = "none"
        if leader.get("error"):
            leader_summary = f"error: {leader['error']}"
        elif leader.get("present"):
            leader_summary = leader["host"]

        def link_extra_class(link: dict) -> str:
            transport = link.get("transport")
            if transport == "tor":
                return " chip-link-tor"
            if transport == "wan":
                return " chip-link-wan"
            return ""

        # Group dashboard links by member host so each row in the Cluster table
        # shows that host's transport links inline — replaces the separate Dashboards panel.
        cluster_members = state["cluster"]["members"]
        links_by_member: dict[str, list] = {m["host"]: [] for m in cluster_members}
        for link in dashboard_links:
            h = link.get("host")
            if h and h in links_by_member:
                links_by_member[h].append(link)

        member_rows = []
        for member in cluster_members:
            host = member["host"]
            badges = []
            if member["isLeader"]:
                badges.append("<span class='badge badge-good'>leader</span>")
            if member["isLocal"]:
                badges.append("<span class='badge badge-muted'>this node</span>")
            badge_html = "".join(badges)
            host_links = links_by_member.get(host, [])
            links_html = "".join(
                f"<a class='chip chip-link chip-sm{link_extra_class(link)}' "
                f"href='{html.escape(link['url'])}' target='_blank' rel='noreferrer'>"
                f"{html.escape(link.get('transport', 'link'))}</a>"
                for link in host_links
            ) if host_links else "<span class='muted'>no links</span>"
            member_rows.append(
                "<tr>"
                f"<td class='member-idx'>{member['priorityIndex'] + 1}</td>"
                f"<td class='member-name'>{badge_html}{html.escape(host)}</td>"
                f"<td>{links_html}</td>"
                "</tr>"
            )

        unit_rows = []
        for unit_name, unit in units.items():
            status_text = unit.get("ActiveState", unit.get("error", "unknown"))
            kind = "good" if unit.get("ActiveState") == "active" else "warn"
            if unit.get("ActiveState") in {"failed", "inactive"}:
                kind = "bad" if unit.get("ActiveState") == "failed" else "muted"
            if unit.get("error"):
                kind = "bad"
            display_name = unit_name.removeprefix("alanix-cluster-")
            unit_rows.append(
                "<tr>"
                f"<td>{html.escape(display_name)}</td>"
                f"<td><span class='badge {badge_class(kind)}'>{html.escape(status_text)}</span></td>"
                f"<td class='muted'>{html.escape(unit.get('SubState', ''))}</td>"
                f"<td class='muted'>{html.escape(unit.get('UnitFileState', ''))}</td>"
                "</tr>"
            )

        current_admin_operation = controller_state.get("adminOperation")
        recent_operations = controller_state.get("recentOperations") or []
        operation_rows = []
        if current_admin_operation:
            operation_rows.append(
                "<tr>"
                f"<td>{html.escape(current_admin_operation.get('action') or 'operation')}</td>"
                f"<td>{html.escape(current_admin_operation.get('service') or '-')}</td>"
                f"<td><span class='badge badge-info'>{html.escape(current_admin_operation.get('status') or 'running')}</span></td>"
                f"<td class='muted'>{html.escape(current_admin_operation.get('requestedBy') or '-')}</td>"
                "</tr>"
            )
        for request in admin_queue[:6]:
            operation_rows.append(
                "<tr>"
                f"<td>{html.escape(request.get('action') or 'operation')}</td>"
                f"<td>{html.escape(request.get('service') or '-')}</td>"
                "<td><span class='badge badge-muted'>queued</span></td>"
                f"<td class='muted'>{html.escape(request.get('requestedBy') or '-')}</td>"
                "</tr>"
            )
        operations_table = (
            "<table><thead><tr><th>Action</th><th>Service</th><th>Status</th><th>User</th></tr></thead><tbody>"
            + ("".join(operation_rows) if operation_rows else "<tr><td colspan='4' class='muted'>No queued or running admin operations.</td></tr>")
            + "</tbody></table>"
        )

        recent_operation_rows = []
        for item in recent_operations[:8]:
            recent_operation_rows.append(
                "<tr>"
                f"<td>{html.escape(item.get('action') or 'operation')}</td>"
                f"<td>{html.escape(item.get('service') or '-')}</td>"
                f"<td><span class='badge {badge_class('good' if item.get('status') == 'completed' else 'warn' if item.get('status') in {'degraded', 'cancelled'} else 'bad')}'>"
                f"{html.escape(item.get('status') or 'unknown')}</span></td>"
                f"<td class='muted'>{html.escape(item.get('message') or '')}</td>"
                "</tr>"
            )
        recent_operations_table = (
            "<table><thead><tr><th>Action</th><th>Service</th><th>Status</th><th>Result</th></tr></thead><tbody>"
            + ("".join(recent_operation_rows) if recent_operation_rows else "<tr><td colspan='4' class='muted'>No recent completed operations yet.</td></tr>")
            + "</tbody></table>"
        )

        login_error_html = (
            f"<div class='admin-message admin-error'>{html.escape(login_error)}</div>"
            if login_error
            else ""
        )
        if admin_enabled and not is_admin:
            admin_panel_html = (
                "<section id='admin-tools' class='panel section'>"
                "<div class='section-head'><h2>Admin Tools</h2></div>"
                "<p class='muted'>Status stays readable for everyone. Sign in to queue backup, verify, restore, pin, and import actions.</p>"
                f"<p class='muted'>Use the current <strong>{html.escape(self.admin_username)}</strong> system password for this machine.</p>"
                f"{login_error_html}"
                "<form method='post' action='/login' class='admin-login'>"
                f"<input type='hidden' name='next' value='/' />"
                f"<input type='text' name='username' value='{html.escape(self.admin_username)}' autocomplete='username' required />"
                "<input type='password' name='password' autocomplete='current-password' placeholder='Password' required />"
                "<button type='submit' class='button'>Sign In</button>"
                "</form>"
                "</section>"
            )
        elif admin_enabled and is_admin:
            admin_panel_html = (
                "<section id='admin-tools' class='panel section'>"
                "<div class='section-head'>"
                "<h2>Admin Tools</h2>"
                "<form method='post' action='/logout'>"
                f"<input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' />"
                "<button type='submit' class='button button-subtle'>Sign Out</button>"
                "</form>"
                "</div>"
                f"<div class='admin-message'>Signed in as <strong>{html.escape(session['username'])}</strong>.</div>"
                f"{operations_table}"
                "<div style='margin-top:0.8rem'></div>"
                f"{recent_operations_table}"
                "</section>"
            )
        else:
            admin_panel_html = ""

        hero_notice_html = ""
        if admin_enabled and not is_admin:
            hero_notice_html = (
                f"<p class='hero-admin-note'>Admin tools are locked. Sign in as <strong>{html.escape(self.admin_username)}</strong> with this computer's current system password.</p>"
            )
        elif admin_enabled and is_admin:
            hero_notice_html = (
                f"<p class='hero-admin-note'>Admin tools unlocked for <strong>{html.escape(session['username'])}</strong>.</p>"
            )
        if login_error:
            hero_notice_html += f"<div class='admin-message admin-error'>{html.escape(login_error)}</div>"

        hero_actions_html = ""
        if admin_enabled and not is_admin:
            hero_actions_html = (
                "<a class='button button-subtle' href='#admin-tools'>Admin Tools</a>"
                "<form method='post' action='/login' class='admin-login hero-login'>"
                f"<input type='hidden' name='next' value='/' />"
                f"<input type='hidden' name='username' value='{html.escape(self.admin_username)}' />"
                f"<span class='badge badge-info'>admin {html.escape(self.admin_username)}</span>"
                "<input type='password' name='password' autocomplete='current-password' placeholder='Current password' required />"
                "<button type='submit' class='button'>Sign In</button>"
                "</form>"
            )
        elif admin_enabled and is_admin:
            hero_actions_html = "<a class='button button-subtle' href='#admin-tools'>Admin Tools</a>"

        service_sections = []
        for service_name, service in services.items():
            readiness = service["promotionReadiness"]
            readiness_kind = "good" if readiness["ready"] else "warn"
            freshest = service["freshestManifest"]
            manifests = service["manifests"]
            active_links = service.get("activeLinks", [])
            if service.get("recoveryMode") == "declarative":
                freshest_html = (
                    "<span class='muted'>No runtime backup required; service identity comes from declarative configuration.</span>"
                )
                config_html = (
                    f"<span class='svc-config muted'>{html.escape(service.get('recoveryDescription') or 'declarative configuration')}</span>"
                )
            elif freshest is None:
                freshest_html = "<span class='muted'>No local manifest</span>"
                config_html = (
                    f"<span class='svc-config muted'>every {html.escape(service['backupInterval'])} · max {html.escape(service['maxBackupAge'])}</span>"
                )
            elif freshest.get("fresh"):
                freshest_html = (
                    f"<strong>{html.escape(freshest.get('sourceHost') or 'unknown')}</strong>"
                    f"<span class='muted'> · {html.escape(freshest.get('ageHuman') or 'unknown')} old"
                    f" · {html.escape(freshest.get('completedAt') or '')}</span>"
                )
                config_html = (
                    f"<span class='svc-config muted'>every {html.escape(service['backupInterval'])} · max {html.escape(service['maxBackupAge'])}</span>"
                )
            else:
                freshest_html = (
                    f"<strong>{html.escape(freshest.get('sourceHost') or 'unknown')}</strong>"
                    f"<span class='text-warn'> · {html.escape(freshest.get('ageHuman') or 'unknown')} old</span>"
                    f"<span class='muted'> · {html.escape(freshest.get('completedAt') or '')}</span>"
                )
                config_html = (
                    f"<span class='svc-config muted'>every {html.escape(service['backupInterval'])} · max {html.escape(service['maxBackupAge'])}</span>"
                )

            current_operation = service.get("currentOperation")
            current_operation_html = ""
            if current_operation:
                progress = current_operation.get("progress") or {}
                detail_bits = []
                if current_operation.get("currentTargetIndex") and current_operation.get("totalTargets"):
                    detail_bits.append(
                        f"overall {current_operation.get('percent', 0.0):.1f}% ({current_operation['currentTargetIndex']}/{current_operation['totalTargets']} targets)"
                    )
                if progress.get("bytesDone") is not None and progress.get("totalBytes") is not None:
                    detail_bits.append(
                        f"current target {format_bytes(progress.get('bytesDone'))} / {format_bytes(progress.get('totalBytes'))}"
                    )
                elif progress.get("filesDone") is not None and progress.get("totalFiles") is not None:
                    detail_bits.append(f"current target {progress.get('filesDone')} / {progress.get('totalFiles')} files")
                if current_operation.get("currentTarget"):
                    detail_bits.append(f"target {current_operation['currentTarget']}")
                detail_html = (
                    f"<span class='op-detail'>{html.escape(' · '.join(detail_bits))}</span>"
                    if detail_bits
                    else ""
                )
                current_operation_html = (
                    "<div class='operation-card'>"
                    "<div class='operation-row'>"
                    f"<strong>{html.escape(current_operation.get('action') or 'operation')}</strong>"
                    f"<span class='badge {badge_class('info')}'>{html.escape(current_operation.get('phase') or 'running')}</span>"
                    f"<span class='op-percent'>{current_operation.get('percent', 0.0):.1f}% overall</span>"
                    "</div>"
                    f"<div class='progress-bar'><span style='width:{max(0.0, min(100.0, float(current_operation.get('percent', 0.0)))):.1f}%'></span></div>"
                    f"{detail_html}"
                    "</div>"
                )

            admin_actions_html = ""
            if is_admin and service.get("recoveryMode") != "declarative":
                manifest_options = "".join(
                    f"<option value='{html.escape(m['path'])}'>{html.escape(m.get('snapshotId') or 'unknown')} · {html.escape(m.get('completedAt') or 'unknown')}</option>"
                    for m in manifests[:20]
                )
                admin_actions_html = (
                    "<div class='admin-actions'>"
                    f"<form method='post' action='/admin/action'><input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' /><input type='hidden' name='action' value='backup-now' /><input type='hidden' name='service' value='{html.escape(service_name)}' /><button type='submit' class='button'>Backup Now</button></form>"
                    + (
                        "<form method='post' action='/admin/action'>"
                        f"<input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' />"
                        "<input type='hidden' name='action' value='verify-manifest' />"
                        f"<input type='hidden' name='service' value='{html.escape(service_name)}' />"
                        f"<select name='manifestPath' required>{manifest_options}</select>"
                        "<button type='submit' class='button button-subtle'>Verify</button>"
                        "</form>"
                        "<form method='post' action='/admin/action'>"
                        f"<input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' />"
                        "<input type='hidden' name='action' value='restore-manifest' />"
                        f"<input type='hidden' name='service' value='{html.escape(service_name)}' />"
                        f"<select name='manifestPath' required>{manifest_options}</select>"
                        "<button type='submit' class='button button-danger'>Restore</button>"
                        "</form>"
                        if manifest_options
                        else ""
                    )
                    + "</div>"
                    + (
                        f"<details class='admin-import' data-detail-key='import-{html.escape(service_name)}'><summary>Import Existing Snapshot</summary>"
                        "<form method='post' action='/admin/action' class='import-form'>"
                        f"<input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' />"
                        "<input type='hidden' name='action' value='import-manifest' />"
                        f"<input type='hidden' name='service' value='{html.escape(service_name)}' />"
                        "<input type='text' name='repoPath' placeholder='Local repo path' required />"
                        "<input type='text' name='snapshotId' placeholder='Snapshot id' required />"
                        "<input type='text' name='sourceHost' placeholder='Source host (optional)' />"
                        "<input type='text' name='completedAt' placeholder='Completed at ISO8601 (optional)' />"
                        "<input type='text' name='note' placeholder='Note (optional)' />"
                        "<button type='submit' class='button button-subtle'>Register Snapshot</button>"
                        "</form></details>"
                    )
                )

            manifest_rows = []
            for manifest in manifests[:8]:
                badges = [
                    f"<span class='badge {badge_class('good' if manifest.get('fresh') else 'warn')}'>{'fresh' if manifest.get('fresh') else 'stale'}</span>"
                ]
                if manifest.get("imported"):
                    badges.append("<span class='badge badge-info'>imported</span>")
                if manifest.get("pinned"):
                    badges.append("<span class='badge badge-good'>pinned</span>")
                notes = []
                if manifest.get("note"):
                    notes.append(manifest["note"])
                if manifest.get("pinNote"):
                    notes.append(f"pin: {manifest['pinNote']}")

                action_html = ""
                if is_admin:
                    pin_action = "unpin-manifest" if manifest.get("pinned") else "pin-manifest"
                    pin_label = "Unpin" if manifest.get("pinned") else "Pin"
                    action_html = (
                        "<div class='table-actions'>"
                        "<form method='post' action='/admin/action'>"
                        f"<input type='hidden' name='csrf_token' value='{html.escape(session['csrfToken'])}' />"
                        f"<input type='hidden' name='action' value='{pin_action}' />"
                        f"<input type='hidden' name='service' value='{html.escape(service_name)}' />"
                        f"<input type='hidden' name='manifestPath' value='{html.escape(manifest['path'])}' />"
                        "<input type='text' name='note' placeholder='pin note' class='table-note-input' />"
                        f"<button type='submit' class='button button-inline'>{html.escape(pin_label)}</button>"
                        "</form>"
                        "</div>"
                    )

                manifest_rows.append(
                    "<tr>"
                    f"<td>{html.escape(manifest.get('sourceHost') or 'unknown')}</td>"
                    f"<td class='muted'>{html.escape(manifest.get('snapshotId') or 'unknown')}</td>"
                    f"<td class='muted'>{html.escape(manifest.get('completedAt') or 'unknown')}</td>"
                    f"<td>{''.join(badges)}{'<div class=\"table-note\">' + html.escape(' · '.join(notes)) + '</div>' if notes else ''}</td>"
                    f"<td class='muted path-cell'>{html.escape(manifest.get('repoPath') or '')}</td>"
                    f"<td>{action_html or '<span class=\"muted\">-</span>'}</td>"
                    "</tr>"
                )
            manifests_table = (
                "<div class='table-wrap'><table><thead><tr>"
                "<th>Source</th><th>Snapshot</th><th>Completed</th><th>Status</th><th>Repo</th><th>Actions</th>"
                "</tr></thead><tbody>"
                + ("".join(manifest_rows) if manifest_rows else "<tr><td colspan='6' class='muted'>No local manifests</td></tr>")
                + "</tbody></table></div>"
            )

            active_units_html = "".join(
                f"<span class='chip chip-sm'>{html.escape(u)}</span>"
                for u in service["activeUnits"]
            ) or "<span class='muted'>None</span>"
            remote_targets_html = "".join(
                f"<span class='chip chip-sm'>{html.escape(h)}</span>"
                for h in service["remoteTargets"]
            ) or "<span class='muted'>None</span>"
            active_links_html = "".join(
                f"<a class='chip chip-link{link_extra_class(link)}' href='{html.escape(link['url'])}' "
                f"target='_blank' rel='noreferrer'>{html.escape(link['label'])}</a>"
                for link in active_links
            ) or "<span class='muted'>Service not running on leader.</span>"

            service_sections.append(
                f"<article class='service-card' data-service-name='{html.escape(service_name)}'>"
                "<div class='service-header'>"
                f"<h3>{html.escape(service_name)}</h3>"
                f"<span class='badge {badge_class(readiness_kind)}'>{html.escape(readiness['reason'])}</span>"
                f"{config_html}"
                "</div>"
                f"<div class='manifest-info'>{freshest_html}</div>"
                f"{current_operation_html}"
                f"{admin_actions_html}"
                f"<div class='link-row'>{active_links_html}</div>"
                f"<details data-detail-key='service-{html.escape(service_name)}'><summary>Details</summary>"
                "<div class='details-body'>"
                f"<div class='detail-row'><span class='detail-label'>Active units</span><span>{active_units_html}</span></div>"
                f"<div class='detail-row'><span class='detail-label'>Remote targets</span><span>{remote_targets_html}</span></div>"
                f"{manifests_table}"
                "</div></details>"
                "</article>"
            )

        events_html = "\n".join(html.escape(line) for line in state["recentEvents"])
        raw_json = html.escape(json.dumps(state, indent=2))

        return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
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
        --tor: #4a2d7a;
        --wan: #1a6b8a;
      }}
      * {{ box-sizing: border-box; }}
      body {{
        margin: 0;
        font-family: "Iosevka Aile", "IBM Plex Sans", "Segoe UI", sans-serif;
        color: var(--text);
        background:
          radial-gradient(circle at top right, rgba(36,69,45,0.10), transparent 28rem),
          linear-gradient(180deg, #fbf7f0, var(--bg));
        min-height: 100vh;
      }}
      main {{ max-width: 80rem; margin: 0 auto; padding: 1.5rem; }}
      h1, h2, h3 {{ margin: 0; font-weight: 700; letter-spacing: -0.02em; }}
      h1 {{ font-size: 1.85rem; }}
      h2 {{
        font-size: 0.72rem;
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: var(--muted);
        margin-bottom: 0.65rem;
      }}
      .section-head {{
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.8rem;
        margin-bottom: 0.65rem;
      }}
      .section-head h2 {{ margin-bottom: 0; }}
      .section-actions {{
        display: flex;
        align-items: center;
        gap: 0.35rem;
      }}
      h3 {{ font-size: 1rem; }}
      .section {{ margin-bottom: 1.1rem; }}
      .panel {{
        background: rgba(255,253,248,0.94);
        border: 1px solid var(--line);
        border-radius: 0.875rem;
        padding: 1rem 1.1rem;
        box-shadow: 0 2px 12px rgba(54,43,22,0.055);
      }}
      .service-card {{
        background: rgba(255,253,248,0.94);
        border: 1px solid var(--line);
        border-radius: 0.875rem;
        padding: 1rem 1.1rem;
        box-shadow: 0 2px 12px rgba(54,43,22,0.055);
      }}
      .button {{
        appearance: none;
        border: 1px solid rgba(36,69,45,0.18);
        background: var(--accent);
        color: #fffdf8;
        border-radius: 0.7rem;
        padding: 0.5rem 0.85rem;
        font: inherit;
        cursor: pointer;
      }}
      .button:hover {{ filter: brightness(1.05); }}
      .button-subtle {{
        background: transparent;
        color: var(--accent);
      }}
      .button-danger {{
        background: var(--bad);
        border-color: rgba(163,54,42,0.28);
      }}
      .button-inline {{
        padding: 0.35rem 0.55rem;
        font-size: 0.78rem;
      }}
      .hero-actions {{
        display: flex;
        align-items: center;
        gap: 0.6rem;
        flex-wrap: wrap;
        justify-content: flex-end;
      }}
      .hero-admin-note {{
        margin: 0.45rem 0 0;
        color: var(--muted);
        font-size: 0.9rem;
      }}
      .admin-login,
      .admin-actions,
      .import-form,
      .table-actions form {{
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
        align-items: center;
      }}
      .admin-login input,
      .admin-actions select,
      .import-form input,
      .table-note-input {{
        min-width: 0;
        border: 1px solid rgba(36,69,45,0.18);
        background: #fffdf8;
        border-radius: 0.65rem;
        padding: 0.5rem 0.65rem;
        font: inherit;
        color: inherit;
      }}
      .admin-login input {{ flex: 1 1 12rem; }}
      .hero-login {{
        justify-content: flex-end;
      }}
      .hero-login input {{
        flex: 0 1 13rem;
      }}
      .admin-actions form {{ margin: 0; }}
      .admin-actions {{
        align-items: flex-start;
      }}
      .admin-message {{
        margin-bottom: 0.8rem;
        color: var(--muted);
        font-size: 0.88rem;
      }}
      .admin-error {{ color: var(--bad); }}
      .admin-import {{
        margin-top: 0.35rem;
      }}
      .operation-card {{
        border: 1px solid rgba(36,69,45,0.12);
        border-radius: 0.8rem;
        padding: 0.75rem 0.85rem;
        background: rgba(36,69,45,0.04);
      }}
      .operation-row {{
        display: flex;
        align-items: center;
        gap: 0.45rem;
        flex-wrap: wrap;
        margin-bottom: 0.45rem;
      }}
      .op-percent {{
        margin-left: auto;
        color: var(--muted);
        font-size: 0.82rem;
      }}
      .op-detail {{
        display: block;
        margin-top: 0.35rem;
        color: var(--muted);
        font-size: 0.82rem;
      }}
      .progress-bar {{
        height: 0.45rem;
        background: rgba(36,69,45,0.10);
        border-radius: 999px;
        overflow: hidden;
      }}
      .progress-bar span {{
        display: block;
        height: 100%;
        background: linear-gradient(90deg, #406e4a, #82a55d);
      }}
      .table-actions form {{ margin: 0; }}
      .table-actions form {{
        align-items: flex-start;
      }}
      .table-note {{
        margin-top: 0.3rem;
        color: var(--muted);
        font-size: 0.78rem;
      }}
      .table-wrap {{
        width: 100%;
        overflow-x: auto;
      }}
      .path-cell {{
        min-width: 14rem;
        max-width: 26rem;
        word-break: break-word;
        white-space: normal;
        font-size: 0.76rem;
      }}
      .service-card details[open] .table-wrap {{
        margin-right: -0.1rem;
      }}
      /* Hero */
      .hero {{
        display: flex;
        justify-content: space-between;
        align-items: flex-end;
        gap: 1rem;
        margin-bottom: 1.1rem;
      }}
      .hero-sub {{ margin: 0.3rem 0 0; color: var(--muted); font-size: 0.88rem; }}
      /* Metrics */
      .grid {{
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
        gap: 0.75rem;
        margin-bottom: 1.1rem;
      }}
      .metric-label {{
        display: block;
        font-size: 0.72rem;
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: var(--muted);
        margin-bottom: 0.3rem;
      }}
      .metric-value {{ font-size: 1.15rem; font-weight: 700; }}
      /* Badges & chips */
      .badge, .chip {{
        display: inline-flex;
        align-items: center;
        border-radius: 999px;
        padding: 0.18rem 0.5rem;
        font-size: 0.78rem;
        line-height: 1.4;
        white-space: nowrap;
      }}
      .badge-good  {{ background: rgba(47,122,69,0.12);  color: var(--good); }}
      .badge-warn  {{ background: rgba(181,107,24,0.12); color: var(--warn); }}
      .badge-bad   {{ background: rgba(163,54,42,0.12);  color: var(--bad); }}
      .badge-muted {{ background: rgba(95,108,98,0.12);  color: var(--muted); }}
      .badge-info  {{ background: rgba(36,95,141,0.12);  color: var(--info); }}
      .chip {{
        background: rgba(36,69,45,0.08);
        color: var(--accent);
        margin: 0 0.3rem 0.3rem 0;
        text-decoration: none;
      }}
      .chip-sm {{ padding: 0.12rem 0.42rem; font-size: 0.75rem; }}
      .chip-link {{ border: 1px solid rgba(36,69,45,0.18); }}
      .chip-link:hover {{ background: rgba(36,69,45,0.14); }}
      .chip-link-tor {{
        background: rgba(74,45,122,0.09);
        color: var(--tor);
        border: 1px solid rgba(74,45,122,0.22);
      }}
      .chip-link-tor:hover {{ background: rgba(74,45,122,0.16); }}
      .chip-link-wan {{
        background: rgba(26,107,138,0.09);
        color: var(--wan);
        border: 1px solid rgba(26,107,138,0.22);
      }}
      .chip-link-wan:hover {{ background: rgba(26,107,138,0.16); }}
      /* Cluster member table */
      .member-table {{ width: 100%; border-collapse: collapse; }}
      .member-table td {{
        padding: 0.48rem 0.35rem;
        border-top: 1px solid rgba(217,204,184,0.4);
        vertical-align: middle;
      }}
      .member-table tr:first-child td {{ border-top: none; }}
      .member-idx {{ width: 1.6rem; color: var(--muted); font-size: 0.8rem; }}
      .member-name {{ width: 13rem; font-weight: 600; }}
      .member-name .badge {{ margin-right: 0.3rem; vertical-align: middle; }}
      /* Unit status */
      .unit-table {{ width: 100%; border-collapse: collapse; margin-top: 0.5rem; font-size: 0.88rem; }}
      .unit-table th, .unit-table td {{
        padding: 0.42rem 0.35rem;
        text-align: left;
        border-top: 1px solid rgba(217,204,184,0.5);
        vertical-align: top;
      }}
      .unit-table th {{
        color: var(--muted);
        font-size: 0.72rem;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.07em;
        border-top: none;
      }}
      /* Services */
      .services {{
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(min(100%, 26rem), 1fr));
        gap: 0.9rem;
      }}
      @supports selector(.service-card:has(details[open])) {{
        .service-card:has(details[open]) {{
          grid-column: 1 / -1;
        }}
      }}
      .service-card {{ display: flex; flex-direction: column; gap: 0.55rem; }}
      .service-header {{
        display: flex;
        align-items: center;
        gap: 0.5rem;
        flex-wrap: wrap;
      }}
      .svc-config {{ font-size: 0.8rem; margin-left: auto; }}
      .manifest-info {{ font-size: 0.88rem; }}
      .text-warn {{ color: var(--warn); }}
      .link-row {{ display: flex; flex-wrap: wrap; }}
      /* Inner manifest table */
      table {{
        width: 100%;
        border-collapse: collapse;
        margin-top: 0.5rem;
        font-size: 0.83rem;
      }}
      th, td {{
        padding: 0.38rem 0.35rem;
        text-align: left;
        border-top: 1px solid rgba(217,204,184,0.55);
        vertical-align: top;
        overflow-wrap: anywhere;
      }}
      th {{
        color: var(--muted);
        font-size: 0.72rem;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.07em;
        border-top: none;
      }}
      /* Details toggle */
      details > summary {{
        cursor: pointer;
        font-size: 0.8rem;
        font-weight: 600;
        color: var(--muted);
        user-select: none;
        list-style: none;
      }}
      details > summary::-webkit-details-marker {{ display: none; }}
      details > summary::before {{ content: "▸  "; font-size: 0.65rem; }}
      details[open] > summary::before {{ content: "▾  "; }}
      details > summary:hover {{ color: var(--accent); }}
      .details-body {{ padding-top: 0.45rem; display: flex; flex-direction: column; gap: 0.35rem; }}
      .detail-row {{ display: flex; gap: 0.6rem; align-items: flex-start; font-size: 0.84rem; }}
      .detail-label {{ min-width: 7rem; color: var(--muted); font-size: 0.78rem; padding-top: 0.25rem; flex-shrink: 0; }}
      /* Events */
      pre {{
        margin: 0;
        padding: 1rem;
        background: #1a211a;
        color: #eef5ec;
        border-radius: 0.875rem;
        overflow: auto;
        font-family: "Iosevka Term", "IBM Plex Mono", monospace;
        font-size: 0.84rem;
        line-height: 1.55;
      }}
      .events-log {{ max-height: 20rem; }}
      .muted {{ color: var(--muted); }}
      .refresh-age {{ font-size: 0.78rem; color: var(--muted); }}
      .icon-button {{
        appearance: none;
        border: 1px solid transparent;
        background: transparent;
        color: var(--muted);
        border-radius: 0.7rem;
        width: 2rem;
        height: 2rem;
        padding: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        transition: background 140ms ease, border-color 140ms ease, color 140ms ease;
      }}
      .icon-button:hover {{
        background: rgba(36,69,45,0.08);
        border-color: rgba(36,69,45,0.12);
        color: var(--accent);
      }}
      .icon-button svg {{
        width: 1rem;
        height: 1rem;
        stroke: currentColor;
        fill: none;
        stroke-width: 1.8;
        stroke-linecap: round;
        stroke-linejoin: round;
      }}
      .icon-button .icon-check {{ display: none; }}
      .icon-button[data-copy-state="copied"] {{
        border-color: rgba(47,122,69,0.28);
        color: var(--good);
        background: rgba(47,122,69,0.08);
      }}
      .icon-button[data-copy-state="copied"] .icon-copy {{ display: none; }}
      .icon-button[data-copy-state="copied"] .icon-check {{ display: inline-flex; }}
      .details-toolbar {{
        display: flex;
        justify-content: flex-end;
        margin-top: 0.6rem;
      }}
      @media (max-width: 680px) {{
        .hero {{ flex-direction: column; align-items: flex-start; }}
        .services {{ grid-template-columns: 1fr; }}
        .member-name {{ width: auto; }}
        .hero-actions {{ justify-content: flex-start; }}
      }}
    </style>
  </head>
  <body>
    <main>
      <section id="hero-section" class="hero">
        <div>
          <h1>Alanix Cluster Dashboard</h1>
          <p class="hero-sub">{html.escape(self.hostname)} · {html.escape(state["cluster"]["name"])} · {html.escape(state["generatedAt"])} <span class="refresh-age" id="last-refreshed-age"></span></p>
          {hero_notice_html}
        </div>
        <div class="hero-actions">
          {hero_actions_html}
          <span class="badge {badge_class(role['kind'])}">{html.escape(role['label'])}</span>
        </div>
      </section>

      <section id="metrics-section" class="grid">
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

      {admin_panel_html}

      <section id="cluster-section" class="panel section">
        <h2>Cluster</h2>
        <table class="member-table">
          <tbody>{''.join(member_rows)}</tbody>
        </table>
      </section>

      <details id="unit-status-section" class="panel section" data-detail-key="unit-status">
        <summary>Unit Status</summary>
        <table class="unit-table">
          <thead><tr><th>Unit</th><th>State</th><th>Substate</th><th>Enabled</th></tr></thead>
          <tbody>{''.join(unit_rows)}</tbody>
        </table>
      </details>

      <section id="services-section" class="section">
        <h2>Services</h2>
        <div class="services">
          {''.join(service_sections) if service_sections else '<div class="panel muted">No clustered services configured yet.</div>'}
        </div>
      </section>

      <section id="events-section" class="section">
        <div class="section-head">
          <h2>Recent Events</h2>
          <div class="section-actions">
            <button class="icon-button" type="button" data-copy-target="recent-events" aria-label="Copy recent events" title="Copy recent events">
              <span class="icon-copy" aria-hidden="true">
                <svg viewBox="0 0 24 24"><rect x="9" y="9" width="10" height="10" rx="2"></rect><path d="M15 9V7a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"></path></svg>
              </span>
              <span class="icon-check" aria-hidden="true">
                <svg viewBox="0 0 24 24"><path d="m5 12 4.5 4.5L19 7"></path></svg>
              </span>
            </button>
          </div>
        </div>
        <pre id="recent-events" class="events-log" data-preserve-scroll="true">{events_html}</pre>
      </section>

      <section id="raw-section" class="section">
        <details data-detail-key="raw-json">
          <summary>Raw JSON</summary>
          <div class="details-toolbar">
            <button class="icon-button" type="button" data-copy-target="raw-json" aria-label="Copy raw JSON" title="Copy raw JSON">
              <span class="icon-copy" aria-hidden="true">
                <svg viewBox="0 0 24 24"><rect x="9" y="9" width="10" height="10" rx="2"></rect><path d="M15 9V7a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"></path></svg>
              </span>
              <span class="icon-check" aria-hidden="true">
                <svg viewBox="0 0 24 24"><path d="m5 12 4.5 4.5L19 7"></path></svg>
              </span>
            </button>
          </div>
          <pre id="raw-json" data-preserve-scroll="true" style="margin-top:0.6rem">{raw_json}</pre>
        </details>
      </section>
    </main>
    <script>
      (function() {{
        var refreshedAt = Date.now();
        var lastInteractionAt = Date.now();
        var refreshPending = false;
        var liveSource = null;
        var reconnectTimer = null;
        var sectionIds = [
          'hero-section',
          'metrics-section',
          'admin-tools',
          'cluster-section',
          'unit-status-section',
          'services-section',
          'events-section',
          'raw-section'
        ];

        function markInteraction() {{
          lastInteractionAt = Date.now();
        }}

        function updateAge() {{
          var el = document.getElementById('last-refreshed-age');
          if (!el) return;
          var s = Math.floor((Date.now() - refreshedAt) / 1000);
          el.textContent = '(' + s + 's ago)';
        }}

        async function copyTargetText(button) {{
          markInteraction();
          var targetId = button.getAttribute('data-copy-target');
          if (!targetId) return;
          var el = document.getElementById(targetId);
          if (!el) return;
          var text = el.textContent || '';
          try {{
            if (navigator.clipboard && navigator.clipboard.writeText) {{
              await navigator.clipboard.writeText(text);
            }} else {{
              var ta = document.createElement('textarea');
              ta.value = text;
              ta.style.position = 'fixed';
              ta.style.opacity = '0';
              document.body.appendChild(ta);
              ta.focus();
              ta.select();
              document.execCommand('copy');
              document.body.removeChild(ta);
            }}
            button.setAttribute('data-copy-label', button.getAttribute('data-copy-label') || button.getAttribute('aria-label') || 'Copy');
            button.setAttribute('data-copy-state', 'copied');
            clearTimeout(button._copyTimer);
            button._copyTimer = setTimeout(function() {{
              button.removeAttribute('data-copy-state');
            }}, 1500);
          }} catch (e) {{}}
        }}

        function preserveScrollState() {{
          var scrolls = {{}};
          document.querySelectorAll('[data-preserve-scroll]').forEach(function(el) {{
            if (el.id) {{
              scrolls[el.id] = el.scrollTop;
            }}
          }});
          return scrolls;
        }}

        function restoreScrollState(scrolls) {{
          Object.keys(scrolls).forEach(function(id) {{
            var el = document.getElementById(id);
            if (el) {{
              el.scrollTop = scrolls[id];
            }}
          }});
        }}

        function userIsReadingScrollable() {{
          var active = document.activeElement;
          if (active && active.hasAttribute && active.hasAttribute('data-preserve-scroll')) {{
            return true;
          }}
          return Array.from(document.querySelectorAll('[data-preserve-scroll]')).some(function(el) {{
            return el.matches(':hover');
          }});
        }}

        function userIsEditingForm() {{
          var active = document.activeElement;
          if (!active) return false;
          if (active.matches && active.matches('input, textarea, select, button')) {{
            return true;
          }}
          if (active.isContentEditable) {{
            return true;
          }}
          return false;
        }}

        function captureOpenDetails() {{
          var openKeys = new Set();
          document.querySelectorAll('details[data-detail-key]').forEach(function(el) {{
            if (el.open) {{
              openKeys.add(el.getAttribute('data-detail-key'));
            }}
          }});
          return openKeys;
        }}

        function restoreOpenDetails(openKeys) {{
          document.querySelectorAll('details[data-detail-key]').forEach(function(el) {{
            var key = el.getAttribute('data-detail-key');
            if (key && openKeys.has(key)) {{
              el.open = true;
            }}
          }});
        }}

        function replaceSectionFromDoc(id, doc) {{
          var next = doc.getElementById(id);
          var current = document.getElementById(id);
          if (!next && !current) return;
          if (!next && current) {{
            current.remove();
            return;
          }}
          if (next && !current) {{
            var anchor = document.getElementById('metrics-section') || document.querySelector('main');
            if (anchor && anchor.parentNode) {{
              anchor.parentNode.insertBefore(next.cloneNode(true), anchor.nextSibling);
            }}
            return;
          }}
          current.replaceWith(next.cloneNode(true));
        }}

        function syncServicesSection(doc) {{
          var currentSection = document.getElementById('services-section');
          var nextSection = doc.getElementById('services-section');
          if (!currentSection || !nextSection) {{
            replaceSectionFromDoc('services-section', doc);
            return;
          }}

          var currentContainer = currentSection.querySelector('.services');
          var nextContainer = nextSection.querySelector('.services');
          if (!currentContainer || !nextContainer) {{
            replaceSectionFromDoc('services-section', doc);
            return;
          }}

          var currentCardsByName = {{}};
          Array.from(currentContainer.querySelectorAll('.service-card[data-service-name]')).forEach(function(card) {{
            currentCardsByName[card.getAttribute('data-service-name')] = card;
          }});

          var nextCards = Array.from(nextContainer.children);
          nextCards.forEach(function(nextChild, index) {{
            if (!nextChild.classList || !nextChild.classList.contains('service-card')) {{
              replaceSectionFromDoc('services-section', doc);
              currentContainer = null;
              return;
            }}
            if (!currentContainer) return;
            var name = nextChild.getAttribute('data-service-name');
            var currentCard = currentCardsByName[name];
            if (!currentCard) {{
              currentCard = nextChild.cloneNode(true);
            }} else if (currentCard.outerHTML !== nextChild.outerHTML) {{
              currentCard.replaceWith(nextChild.cloneNode(true));
              currentCard = currentContainer.querySelector('.service-card[data-service-name="' + name + '"]');
            }}
            var expectedSlot = currentContainer.children[index] || null;
            if (currentCard !== expectedSlot) {{
              currentContainer.insertBefore(currentCard, expectedSlot);
            }}
          }});
          if (!currentContainer) return;

          Array.from(currentContainer.querySelectorAll('.service-card[data-service-name]')).forEach(function(card) {{
            var name = card.getAttribute('data-service-name');
            var stillExists = nextContainer.querySelector('.service-card[data-service-name="' + name + '"]');
            if (!stillExists) {{
              card.remove();
            }}
          }});
        }}

        document.addEventListener('click', function(ev) {{
          var button = ev.target.closest('[data-copy-target]');
          if (!button) return;
          ev.preventDefault();
          copyTargetText(button);
        }});
        document.addEventListener('scroll', markInteraction, true);
        document.addEventListener('wheel', markInteraction, {{ passive: true }});
        document.addEventListener('touchmove', markInteraction, {{ passive: true }});
        document.addEventListener('keydown', markInteraction, true);
        document.addEventListener('pointerdown', markInteraction, true);
        document.addEventListener('visibilitychange', function() {{
          if (!document.hidden) {{
            scheduleRefresh();
          }}
        }});

        setInterval(updateAge, 1000);
        updateAge();

        async function refresh() {{
          refreshPending = false;
          try {{
            if (document.hidden) return;
            if (Date.now() - lastInteractionAt < 1200) return;
            if (userIsReadingScrollable()) return;
            if (userIsEditingForm()) return;
            var selection = window.getSelection ? window.getSelection().toString() : '';
            if (selection) return;
            var y = window.scrollY;
            var preservedScrolls = preserveScrollState();
            var openDetails = captureOpenDetails();
            var res = await fetch('/');
            if (!res.ok) return;
            var doc = new DOMParser().parseFromString(await res.text(), 'text/html');
            sectionIds.forEach(function(id) {{
              if (id === 'services-section') {{
                syncServicesSection(doc);
              }} else {{
                replaceSectionFromDoc(id, doc);
              }}
            }});
            restoreOpenDetails(openDetails);
            refreshedAt = Date.now();
            updateAge();
            requestAnimationFrame(function() {{
              restoreScrollState(preservedScrolls);
              window.scrollTo(0, y);
            }});
          }} catch(e) {{}}
        }}

        function scheduleRefresh() {{
          if (refreshPending) return;
          refreshPending = true;
          window.setTimeout(refresh, 120);
        }}

        function connectLive() {{
          if (!window.EventSource) return;
          if (liveSource) {{
            liveSource.close();
          }}
          liveSource = new EventSource('/api/events');
          liveSource.addEventListener('update', function() {{
            scheduleRefresh();
          }});
          liveSource.onerror = function() {{
            if (liveSource) {{
              liveSource.close();
              liveSource = null;
            }}
            if (reconnectTimer) {{
              window.clearTimeout(reconnectTimer);
            }}
            reconnectTimer = window.setTimeout(connectLive, 3000);
          }};
        }}

        connectLive();
      }})();
    </script>
  </body>
</html>
"""


class RequestHandler(BaseHTTPRequestHandler):
    dashboard: Dashboard

    def current_session(self):
        return self.dashboard.session_from_cookie(self.headers.get("Cookie"))

    def parse_form_body(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length > 0 else ""
        parsed = urllib.parse.parse_qs(raw, keep_blank_values=True)
        return {key: values[-1] for key, values in parsed.items()}

    def csrf_valid(self, session: dict | None, form: dict[str, str]) -> bool:
        if session is None:
            return False
        return secrets.compare_digest(form.get("csrf_token", ""), session.get("csrfToken", ""))

    def respond_bytes(self, status: int, payload: bytes, content_type: str, *, headers: list[tuple[str, str]] | None = None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if headers:
            for key, value in headers:
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def redirect(self, location: str, *, headers: list[tuple[str, str]] | None = None):
        self.send_response(303)
        self.send_header("Location", location)
        if headers:
            for key, value in headers:
                self.send_header(key, value)
        self.end_headers()

    def handle_event_stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        last_runtime_mtime = None
        last_ping_at = 0.0

        try:
            while True:
                runtime_exists = self.dashboard.runtime_state_file.exists()
                runtime_mtime = (
                    self.dashboard.runtime_state_file.stat().st_mtime_ns
                    if runtime_exists
                    else 0
                )
                if runtime_mtime != last_runtime_mtime:
                    payload = json.dumps({"updatedAt": iso_timestamp()}).encode("utf-8")
                    self.wfile.write(b"event: update\n")
                    self.wfile.write(b"data: ")
                    self.wfile.write(payload)
                    self.wfile.write(b"\n\n")
                    self.wfile.flush()
                    last_runtime_mtime = runtime_mtime
                    last_ping_at = time.time()
                elif time.time() - last_ping_at >= 15.0:
                    self.wfile.write(b"event: ping\ndata: {}\n\n")
                    self.wfile.flush()
                    last_ping_at = time.time()
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/events":
            self.handle_event_stream()
            return

        session = self.current_session()
        state = self.dashboard.collect()
        if path == "/api/status":
            payload = json.dumps(state, indent=2).encode("utf-8")
            self.respond_bytes(200, payload, "application/json; charset=utf-8")
            return

        if path in {"/", ""}:
            payload = self.dashboard.render_html(state, session=session).encode("utf-8")
            self.respond_bytes(200, payload, "text/html; charset=utf-8")
            return

        if path == "/healthz":
            payload = b"ok\n"
            self.respond_bytes(200, payload, "text/plain; charset=utf-8")
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        session = self.current_session()
        form = self.parse_form_body()
        path = urllib.parse.urlsplit(self.path).path

        if path == "/login":
            username = form.get("username", "")
            password = form.get("password", "")
            if not self.dashboard.verify_password(username, password):
                state = self.dashboard.collect()
                payload = self.dashboard.render_html(
                    state,
                    session=None,
                    login_error="Sign-in failed. Check the password and try again.",
                ).encode("utf-8")
                self.respond_bytes(401, payload, "text/html; charset=utf-8")
                return

            session = self.dashboard.create_session(username)
            cookie = (
                f"alanix_cluster_session={session['id']}; Path=/; HttpOnly; SameSite=Strict"
            )
            self.redirect("/", headers=[("Set-Cookie", cookie)])
            return

        if path == "/logout":
            if session is not None and not self.csrf_valid(session, form):
                payload = b"forbidden\n"
                self.respond_bytes(403, payload, "text/plain; charset=utf-8")
                return
            if session is not None:
                self.dashboard.destroy_session(session.get("id"))
            cookie = "alanix_cluster_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
            self.redirect("/", headers=[("Set-Cookie", cookie)])
            return

        if path == "/admin/action":
            if session is None or not self.csrf_valid(session, form):
                payload = b"forbidden\n"
                self.respond_bytes(403, payload, "text/plain; charset=utf-8")
                return

            action = form.get("action", "")
            request = {
                "action": action,
                "service": form.get("service"),
                "manifestPath": form.get("manifestPath"),
                "repoPath": form.get("repoPath"),
                "snapshotId": form.get("snapshotId"),
                "sourceHost": form.get("sourceHost"),
                "completedAt": form.get("completedAt"),
                "note": form.get("note"),
                "requestedBy": session["username"],
            }
            self.dashboard.queue_admin_request(request)
            self.redirect("/")
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
