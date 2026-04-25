#!/usr/bin/env python3

import glob
import html
import hashlib
import http.cookies
import json
import os
import secrets
import shlex
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
        self.admin_enabled = bool(admin_toggle) and bool(self.admin.get("passwordFile"))
        self.admin_username = self.admin.get("username") or "buddia"
        self.admin_password_file = self.admin.get("passwordFile")
        self.admin_session_ttl = parse_duration_seconds(self.admin.get("sessionTtl", "12h"))
        self.sessions = {}
        self.sessions_lock = threading.Lock()
        self.restic_password_file = self.cluster["backup"]["passwordFile"]
        self.snapshot_size_probes_per_collect = 2
        self.snapshot_size_retry_seconds = 300.0
        self.snapshot_size_retry_at: dict[str, float] = {}

        self._state_cond = threading.Condition()
        self._state_seq: int = 0
        self._cached_state: dict | None = None
        t = threading.Thread(target=self._state_collector_loop, daemon=True)
        t.start()

    def _state_collector_loop(self) -> None:
        last_mtime: int | None = None
        last_collect_at: float = 0.0
        PERIODIC_INTERVAL = 5.0

        while True:
            now = time.time()
            try:
                mtime = (
                    self.runtime_state_file.stat().st_mtime_ns
                    if self.runtime_state_file.exists()
                    else 0
                )
            except OSError:
                mtime = 0

            if mtime != last_mtime or now - last_collect_at >= PERIODIC_INTERVAL:
                try:
                    state = self.collect()
                except Exception:
                    time.sleep(1.0)
                    continue
                with self._state_cond:
                    self._cached_state = state
                    self._state_seq += 1
                    self._state_cond.notify_all()
                last_mtime = mtime
                last_collect_at = now

            time.sleep(0.25)

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
            print("alanix-dashboard auth: rejected because admin auth is disabled", file=sys.stderr, flush=True)
            return False
        if username != self.admin_username or not self.admin_password_file:
            print(
                f"alanix-dashboard auth: rejected username={username!r} expected={self.admin_username!r} "
                f"password_file_present={bool(self.admin_password_file)}",
                file=sys.stderr,
                flush=True,
            )
            return False

        try:
            expected = Path(self.admin_password_file).read_text(encoding="utf-8").strip()
        except OSError as exc:
            print(f"alanix-dashboard auth: could not read password file: {exc}", file=sys.stderr, flush=True)
            return False

        if not expected:
            print("alanix-dashboard auth: password file is empty", file=sys.stderr, flush=True)
            return False

        if secrets.compare_digest(password, expected):
            print(f"alanix-dashboard auth: successful login for {username!r}", file=sys.stderr, flush=True)
            return True

        print(f"alanix-dashboard auth: password mismatch for {username!r}", file=sys.stderr, flush=True)
        return False

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

    def restic_snapshot_size(self, repo_path: str, snapshot_id: str) -> int | None:
        try:
            proc = self.run(
                ["restic", "--json", "-r", repo_path, "stats", "--mode", "restore-size", snapshot_id],
                env={"RESTIC_PASSWORD_FILE": self.restic_password_file},
                timeout=10.0,
                check=False,
            )
            if proc.returncode != 0:
                return None
            payload = json.loads(proc.stdout or "{}")
            size = payload.get("total_size")
            return int(size) if size is not None else None
        except Exception:
            return None

    def populate_manifest_snapshot_size(self, manifest_path: Path, payload: dict, *, probe_budget: list[int]) -> int | None:
        manifest_key = str(manifest_path)
        retry_at = self.snapshot_size_retry_at.get(manifest_key, 0.0)
        if probe_budget[0] <= 0 or time.time() < retry_at:
            return None

        repo_path = payload.get("repoPath")
        snapshot_id = payload.get("snapshotId")
        if not repo_path or not snapshot_id:
            return None

        probe_budget[0] -= 1
        snap_size = self.restic_snapshot_size(repo_path, snapshot_id)
        if snap_size is None:
            self.snapshot_size_retry_at[manifest_key] = time.time() + self.snapshot_size_retry_seconds
            return None

        self.snapshot_size_retry_at.pop(manifest_key, None)
        updated_payload = dict(payload)
        updated_payload["snapshotSizeBytes"] = snap_size
        atomic_write_json(manifest_path, updated_payload)
        payload["snapshotSizeBytes"] = snap_size
        return snap_size

    def manifest_state(self, service_name: str, service: dict, *, probe_budget: list[int]) -> dict:
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
        manifest_globs = [service["localManifestGlob"]]
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
                snap_size = payload.get("snapshotSizeBytes")
                if snap_size is not None:
                    try:
                        snap_size = int(snap_size)
                    except (TypeError, ValueError):
                        snap_size = None
                if snap_size is None:
                    snap_size = self.populate_manifest_snapshot_size(
                        manifest_path,
                        payload,
                        probe_budget=probe_budget,
                    )
                manifests.append(
                    {
                        "path": str(manifest_path),
                        "service": payload.get("service"),
                        "sourceHost": payload.get("sourceHost"),
                        "leaderRevision": payload.get("leaderRevision"),
                        "completedAt": payload.get("completedAt"),
                        "snapshotId": payload.get("snapshotId"),
                        "repoPath": payload.get("repoPath"),
                        "repoUri": payload.get("repoUri"),
                        "snapshotSizeBytes": snap_size,
                        "sizeHuman": format_bytes(snap_size) if snap_size is not None else "",
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

        probe_budget = [self.snapshot_size_probes_per_collect]
        services = {
            service_name: self.manifest_state(service_name, service, probe_budget=probe_budget)
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

    def render_html(self, state: dict, *, session: dict | None = None, login_error: str | None = None) -> str:  # noqa: C901
        leader = state["cluster"]["leader"]
        role = state["cluster"]["role"]
        units = state["units"]
        services = state["services"]
        dashboard_links = state.get("dashboardLinks", [])
        controller_state = state.get("controllerState") or {}
        admin_queue = state.get("adminQueue") or []
        admin_enabled = bool(state.get("adminConfig", {}).get("enabled"))
        is_admin = session is not None and admin_enabled
        csrf = html.escape(session["csrfToken"]) if session else ""

        # ── helpers ───────────────────────────────────────────────────────────
        def b(text: str, kind: str) -> str:
            return f"<span class='badge badge-{kind}'>{html.escape(text)}</span>"

        def chip_link(link: dict) -> str:
            t = link.get("transport", "")
            extra = f" chip-{t}" if t in ("tor", "wan", "tailscale", "wireguard") else ""
            return (
                f"<a class='chip chip-link{extra}' href='{html.escape(link['url'])}' "
                f"target='_blank' rel='noreferrer'>{html.escape(link.get('transport', 'link'))}</a>"
            )

        def admin_btn(action: str, svc: str, *, manifest: str = "", extra: str = "", label: str, css: str = "button button-sm", confirm_msg: str = "") -> str:
            mp = f"<input type='hidden' name='manifestPath' value='{html.escape(manifest)}'/>" if manifest else ""
            confirm_js = html.escape(json.dumps(confirm_msg), quote=True) if confirm_msg else ""
            confirm_attr = f' onclick="return confirm({confirm_js})"' if confirm_msg else ""
            return (
                f"<form method='post' action='/admin/action' class='ifrm'>"
                f"<input type='hidden' name='csrf_token' value='{csrf}'/>"
                f"<input type='hidden' name='action' value='{html.escape(action)}'/>"
                f"<input type='hidden' name='service' value='{html.escape(svc)}'/>"
                f"{mp}{extra}"
                f"<button type='submit' class='{html.escape(css)}'{confirm_attr}>{html.escape(label)}</button>"
                f"</form>"
            )

        def progress_html(op: dict) -> str:
            pct = max(0.0, min(100.0, float(op.get("percent", 0.0))))
            prog = op.get("progress") or {}
            phase = op.get("phase") or op.get("action") or "running"
            bd = prog.get("bytesDone")
            tb = prog.get("totalBytes")
            fd = prog.get("filesDone")
            tf = prog.get("totalFiles")
            stats: list[str] = []
            # Only show bytes/files when the current sub-step is still in flight.
            # If bytesDone >= totalBytes the sub-step finished and the stale numbers
            # would contradict the overall percent (e.g. 239/239 MiB at 50%).
            step_in_flight = bd is not None and tb and bd < tb
            if step_in_flight:
                stats.append(f"{format_bytes(bd)} / {format_bytes(tb)}")
            elif bd is not None and not tb:
                stats.append(format_bytes(bd))
            elif fd is not None and tf and fd < tf:
                stats.append(f"{fd} / {tf} files")
            ti = op.get("currentTargetIndex")
            tt = op.get("totalTargets")
            if ti and tt:
                stats.append(f"target {ti}/{tt}")
            right = f"{pct:.0f}%" + ((" · " + " · ".join(stats)) if stats else "")
            return (
                f"<div class='prog-wrap'>"
                f"<div class='prog-hd'><span>{html.escape(phase)}</span>"
                f"<span class='prog-stats'>{html.escape(right)}</span></div>"
                f"<div class='prog-bar'><span style='width:{pct:.2f}%'></span></div>"
                f"</div>"
            )

        # ── admin bar ─────────────────────────────────────────────────────────
        if admin_enabled and is_admin:
            admin_bar = (
                "<div id='admin-bar' class='admin-bar signed-in'>"
                f"Signed in as <strong>{html.escape(session['username'])}</strong>"
                f"<form method='post' action='/logout' class='ifrm'>"
                f"<input type='hidden' name='csrf_token' value='{csrf}'/>"
                "<button type='submit' class='button button-sm button-subtle'>Sign Out</button>"
                "</form></div>"
            )
        elif admin_enabled:
            err = f"<span class='auth-err'>{html.escape(login_error)}</span>" if login_error else ""
            admin_bar = (
                f"<div id='admin-bar' class='admin-bar'>"
                f"<form method='post' action='/login' class='ifrm login-form'>"
                f"<input type='hidden' name='username' value='{html.escape(self.admin_username)}'/>"
                f"<label class='admin-label'>Admin</label>"
                f"<input type='password' name='password' placeholder='Password' autocomplete='current-password'/>"
                f"<button type='submit' class='button button-sm'>Sign In</button>"
                f"</form>{err}</div>"
            )
        else:
            admin_bar = "<div id='admin-bar'></div>"

        # ── ops banner ────────────────────────────────────────────────────────
        cur_admin_op = controller_state.get("adminOperation")
        if is_admin and (cur_admin_op or admin_queue):
            rows: list[str] = []
            if cur_admin_op:
                rows.append(
                    f"<tr><td>{html.escape(cur_admin_op.get('action',''))}</td>"
                    f"<td>{html.escape(cur_admin_op.get('service',''))}</td>"
                    f"<td>{b(cur_admin_op.get('status','running'),'info')}</td>"
                    f"<td class='muted'>{html.escape(cur_admin_op.get('requestedBy',''))}</td></tr>"
                )
            for q in admin_queue[:5]:
                rows.append(
                    f"<tr><td>{html.escape(q.get('action',''))}</td>"
                    f"<td>{html.escape(q.get('service',''))}</td>"
                    f"<td>{b('queued','muted')}</td>"
                    f"<td class='muted'>{html.escape(q.get('requestedBy',''))}</td></tr>"
                )
            ops_banner = (
                f"<section id='ops-banner' class='panel section'>"
                f"<div class='sh'><h2>Admin Operations</h2></div>"
                f"<table><thead><tr><th>Action</th><th>Service</th><th>Status</th><th>By</th></tr></thead>"
                f"<tbody>{''.join(rows)}</tbody></table></section>"
            )
        else:
            ops_banner = "<section id='ops-banner'></section>"

        # ── service cards ─────────────────────────────────────────────────────
        cards: list[str] = []
        for svc_name, svc in services.items():
            readiness = svc["promotionReadiness"]
            manifests = svc.get("manifests") or []
            active_links = svc.get("activeLinks") or []
            cur_op = svc.get("currentOperation")
            is_decl = svc.get("recoveryMode") == "declarative"

            r_kind = "good" if readiness["ready"] else "warn"
            r_reason = readiness["reason"]
            links_row = "".join(chip_link(l) for l in active_links) or "<span class='muted'>Service not on leader.</span>"
            backup_btn = admin_btn("backup-now", svc_name, label="Backup Now") if (is_admin and not is_decl) else ""
            op_html = progress_html(cur_op) if cur_op else ""

            if is_decl:
                blist = f"<p class='muted small'>{html.escape(svc.get('recoveryDescription') or 'Declarative — no backup needed.')}</p>"
            elif not manifests:
                interval = svc.get("backupInterval", "?")
                blist = f"<p class='muted small'>No backups yet. Scheduled every {html.escape(interval)}.</p>"
            else:
                interval = svc.get("backupInterval", "?")
                max_age = svc.get("maxBackupAge", "?")
                brows: list[str] = []
                for m in manifests[:8]:
                    fresh = m.get("fresh", False)
                    pinned = m.get("pinned", False)
                    src = m.get("sourceHost") or "unknown"
                    age = m.get("ageHuman") or "?"
                    snap_full = m.get("snapshotId") or ""
                    snap = snap_full[:12]
                    completed = m.get("completedAt") or ""
                    status_badges = b("fresh" if fresh else "stale", "good" if fresh else "warn")
                    if pinned:
                        status_badges += b("pinned", "info")
                    note = m.get("note") or m.get("pinNote") or ""
                    note_html = f"<span class='bkp-note muted'>{html.escape(note)}</span>" if note else ""
                    size_human = m.get("sizeHuman") or ""
                    restore_btn = admin_btn("restore-manifest", svc_name, manifest=m["path"], label="Restore", css="button button-sm button-danger") if is_admin else ""
                    if is_admin and pinned:
                        delete_btn = (
                            "<button type='button' class='button button-sm button-delete' "
                            "disabled title='Unpin this backup before deleting it'>Delete</button>"
                        )
                    elif is_admin:
                        delete_btn = admin_btn(
                            "delete-manifest",
                            svc_name,
                            manifest=m["path"],
                            label="Delete",
                            css="button button-sm button-delete",
                            confirm_msg="Delete this backup snapshot and its stored data? This cannot be undone.",
                        )
                    else:
                        delete_btn = ""
                    snap_title = html.escape(snap_full)
                    size_html = f"<span class='bkp-size muted'>{html.escape(size_human)}</span>" if size_human else "<span class='bkp-size'></span>"
                    brows.append(
                        f"<div class='bkp-row'>"
                        f"<span class='bkp-age' title='{html.escape(completed)}'>{html.escape(age)}</span>"
                        f"<span class='bkp-src'>{html.escape(src)}</span>"
                        f"<span class='bkp-st'>{status_badges}{note_html}</span>"
                        f"{size_html}"
                        f"<code class='bkp-snap' title='{snap_title}'>{html.escape(snap)}</code>"
                        f"<span class='bkp-act'>{delete_btn}{restore_btn}</span>"
                        f"</div>"
                    )
                blist = (
                    f"<div class='bkp-sched muted small'>Every {html.escape(interval)} · max age {html.escape(max_age)}</div>"
                    f"<div class='bkp-list'>{''.join(brows)}</div>"
                )

            cards.append(
                f"<article class='svc-card' data-service-name='{html.escape(svc_name)}'>"
                f"<div class='svc-hd'>"
                f"<div class='svc-hd-top'>"
                f"<div class='svc-title'><h3>{html.escape(svc_name)}</h3>{b(r_reason, r_kind)}</div>"
                f"<div class='svc-acts'>{backup_btn}</div>"
                f"</div>"
                f"<div class='svc-links'>{links_row}</div>"
                f"</div>"
                f"{op_html}"
                f"<div class='bkp-section'>{blist}</div>"
                f"</article>"
            )

        services_html = (
            "<section id='services-section' class='section'>"
            "<div class='sh'><h2>Services</h2></div>"
            "<div class='services'>"
            + ("".join(cards) if cards else "<p class='muted'>No clustered services configured.</p>")
            + "</div></section>"
        )

        # ── cluster panel ─────────────────────────────────────────────────────
        leader_host = leader.get("host") if leader.get("present") else None
        cluster_members = state["cluster"]["members"]
        lbm: dict[str, list] = {m["host"]: [] for m in cluster_members}
        for lnk in dashboard_links:
            h = lnk.get("host")
            if h and h in lbm:
                lbm[h].append(lnk)
        mrows: list[str] = []
        for m in cluster_members:
            host = m["host"]
            badges = ("" + (b("leader", "good") if m["isLeader"] else "") + (b("this node", "muted") if m["isLocal"] else ""))
            hlinks = "".join(chip_link(l) for l in lbm.get(host, [])) or "<span class='muted'>no links</span>"
            mrows.append(
                f"<tr><td class='muted idx'>{m['priorityIndex']+1}</td>"
                f"<td class='host-nm'>{html.escape(host)}{badges}</td>"
                f"<td>{hlinks}</td></tr>"
            )
        leader_str = leader_host or ("error" if leader.get("error") else "none")
        cluster_panel = (
            f"<details id='cluster-panel' class='panel-details section' data-detail-key='cluster-panel'>"
            f"<summary><span class='sum-title'>Cluster</span>"
            f"<span class='sum-note muted'>leader: {html.escape(leader_str)}</span></summary>"
            f"<div class='panel-body'><table><thead><tr><th>#</th><th>Host</th><th>Links</th></tr></thead>"
            f"<tbody>{''.join(mrows)}</tbody></table></div></details>"
        )

        # ── units panel ───────────────────────────────────────────────────────
        urows: list[str] = []
        for uname, u in units.items():
            st = u.get("ActiveState", u.get("error", "unknown"))
            k = "good" if st == "active" else "bad" if st == "failed" else "muted" if st == "inactive" else "warn"
            if u.get("error"):
                k = "bad"
            disp = uname.removeprefix("alanix-cluster-")
            urows.append(
                f"<tr><td>{html.escape(disp)}</td><td>{b(st, k)}</td>"
                f"<td class='muted small'>{html.escape(u.get('SubState',''))}</td></tr>"
            )
        units_panel = (
            f"<details id='units-panel' class='panel-details section' data-detail-key='units-panel'>"
            f"<summary><span class='sum-title'>Units</span></summary>"
            f"<div class='panel-body'><table><thead><tr><th>Unit</th><th>State</th><th>Sub</th></tr></thead>"
            f"<tbody>{''.join(urows)}</tbody></table></div></details>"
        )

        # ── events panel ──────────────────────────────────────────────────────
        events_text = "\n".join(html.escape(line) for line in state["recentEvents"])
        events_panel = (
            f"<details id='events-panel' class='panel-details section' data-detail-key='events-panel'>"
            f"<summary><span class='sum-title'>Events</span></summary>"
            f"<div class='panel-body'>"
            f"<pre class='events-pre' data-preserve-scroll='true'>"
            f"{events_text or '<span class=\"muted\">No events yet.</span>'}"
            f"</pre></div></details>"
        )

        # ── page ──────────────────────────────────────────────────────────────
        return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Alanix · {html.escape(self.cluster["name"])} · {html.escape(self.hostname)}</title>
  <style>
    :root {{
      --bg: #f5f0e8; --panel: #fffdf8; --border: #d4c8b4;
      --text: #1a2018; --muted: #5a6659;
      --good: #2a7040; --warn: #a85c10; --bad: #8f2a20; --info: #1e5580;
      --accent: #24452d;
    }}
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
      font-size: 14px; line-height: 1.5;
      color: var(--text); background: var(--bg); min-height: 100vh;
    }}
    a {{ color: inherit; }}
    /* ── layout ── */
    .site-hd {{
      background: var(--panel); border-bottom: 1px solid var(--border);
      padding: 0.6rem 1.25rem;
      display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;
    }}
    .brand {{ display: flex; align-items: baseline; gap: 0.6rem; flex: 1; min-width: 0; }}
    .cluster-nm {{ font-weight: 700; font-size: 1rem; letter-spacing: -0.01em; }}
    .node-nm {{ font-size: 0.82rem; }}
    .hd-right {{ display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }}
    main {{ max-width: 72rem; margin: 0 auto; padding: 1.1rem 1.25rem; display: flex; flex-direction: column; gap: 0.85rem; }}
    /* ── admin bar ── */
    .admin-bar {{
      background: rgba(36,69,45,0.06); border: 1px solid var(--border);
      border-radius: 0.65rem; padding: 0.45rem 0.75rem;
      display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap;
    }}
    .admin-bar.signed-in {{ background: rgba(42,112,64,0.08); border-color: rgba(42,112,64,0.22); }}
    .login-form {{ display: flex; align-items: center; gap: 0.45rem; flex-wrap: wrap; }}
    .admin-label {{ font-size: 0.8rem; color: var(--muted); font-weight: 600; }}
    .auth-err {{ color: var(--bad); font-size: 0.82rem; }}
    input[type="password"], input[type="text"] {{
      border: 1px solid var(--border); background: var(--panel);
      border-radius: 0.5rem; padding: 0.3rem 0.6rem;
      font: inherit; color: inherit; min-width: 0;
    }}
    /* ── section header ── */
    .sh {{ display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.5rem; }}
    .sh h2 {{
      font-size: 0.7rem; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.1em;
      color: var(--muted);
    }}
    /* ── panel / details ── */
    .panel {{
      background: var(--panel); border: 1px solid var(--border);
      border-radius: 0.75rem; padding: 0.85rem 1rem;
    }}
    .panel-details {{
      background: var(--panel); border: 1px solid var(--border);
      border-radius: 0.75rem; padding: 0.75rem 1rem;
    }}
    .panel-details > summary {{
      cursor: pointer; user-select: none; list-style: none;
      display: flex; align-items: center; gap: 0.6rem;
    }}
    .panel-details > summary::-webkit-details-marker {{ display: none; }}
    .panel-details > summary::before {{
      content: "▸"; font-size: 0.65rem; color: var(--muted); flex-shrink: 0;
    }}
    .panel-details[open] > summary::before {{ content: "▾"; }}
    .sum-title {{
      font-size: 0.7rem; font-weight: 700; text-transform: uppercase;
      letter-spacing: 0.1em; color: var(--muted);
    }}
    .sum-note {{ font-size: 0.78rem; }}
    .panel-body {{ padding-top: 0.6rem; }}
    /* ── badges ── */
    .badge {{
      display: inline-flex; align-items: center;
      border-radius: 999px; padding: 0.15rem 0.45rem;
      font-size: 0.75rem; line-height: 1.4; white-space: nowrap; font-weight: 500;
    }}
    .badge-good  {{ background: rgba(42,112,64,0.12); color: var(--good); }}
    .badge-warn  {{ background: rgba(168,92,16,0.12); color: var(--warn); }}
    .badge-bad   {{ background: rgba(143,42,32,0.12); color: var(--bad); }}
    .badge-muted {{ background: rgba(90,102,89,0.12); color: var(--muted); }}
    .badge-info  {{ background: rgba(30,85,128,0.12); color: var(--info); }}
    /* ── chips ── */
    .chip {{
      display: inline-flex; align-items: center;
      border-radius: 999px; padding: 0.15rem 0.5rem;
      font-size: 0.75rem; text-decoration: none; white-space: nowrap;
      background: rgba(36,69,45,0.08); color: var(--accent);
      border: 1px solid rgba(36,69,45,0.18);
    }}
    .chip-link:hover {{ background: rgba(36,69,45,0.14); }}
    .chip-tor {{ background: rgba(74,45,122,0.09); color: #4a2d7a; border-color: rgba(74,45,122,0.22); }}
    .chip-wan {{ background: rgba(26,107,138,0.09); color: #1a6b8a; border-color: rgba(26,107,138,0.22); }}
    /* ── buttons ── */
    .button {{
      appearance: none; cursor: pointer; font: inherit;
      border: 1px solid rgba(36,69,45,0.2); background: var(--accent);
      color: #fff; border-radius: 0.55rem; padding: 0.4rem 0.75rem;
    }}
    .button:not(:disabled):hover {{ filter: brightness(1.1); }}
    .button-sm {{ padding: 0.25rem 0.55rem; font-size: 0.8rem; }}
    .button-subtle {{ background: transparent; color: var(--accent); }}
    .button-danger {{ background: var(--bad); border-color: rgba(143,42,32,0.25); }}
    .button-delete {{ background: #6b7280; border-color: rgba(75,85,99,0.3); }}
    .button:disabled {{ cursor: not-allowed; opacity: 0.55; filter: none; }}
    .ifrm {{ display: inline; margin: 0; padding: 0; }}
    /* ── services grid ── */
    .services {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(100%, 28rem), 1fr));
      gap: 0.75rem;
    }}
    .svc-card {{
      background: var(--panel); border: 1px solid var(--border);
      border-radius: 0.75rem; padding: 0.85rem 1rem;
      display: flex; flex-direction: column; gap: 0.6rem;
    }}
    .svc-hd {{ display: flex; flex-direction: column; gap: 0.35rem; }}
    .svc-hd-top {{ display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; min-width: 0; }}
    .svc-title {{ display: flex; align-items: center; gap: 0.4rem; min-width: 0; overflow: hidden; }}
    .svc-title h3 {{ font-size: 0.95rem; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
    .svc-links {{ display: flex; flex-wrap: wrap; gap: 0.25rem; align-items: center; }}
    .svc-acts {{ flex-shrink: 0; display: flex; gap: 0.3rem; align-items: center; }}
    /* ── progress ── */
    .prog-wrap {{
      border: 1px solid rgba(36,69,45,0.12); border-radius: 0.6rem;
      padding: 0.55rem 0.75rem; background: rgba(36,69,45,0.04);
    }}
    .prog-hd {{
      display: flex; justify-content: space-between; align-items: center;
      gap: 0.5rem; font-size: 0.8rem; margin-bottom: 0.35rem; font-weight: 600;
    }}
    .prog-stats {{ color: var(--muted); font-weight: 400; }}
    .prog-bar {{
      height: 0.5rem; background: rgba(36,69,45,0.1);
      border-radius: 999px; overflow: hidden;
    }}
    .prog-bar span {{
      display: block; height: 100%;
      background: linear-gradient(90deg, var(--good), #5fa86e);
      transition: width 0.4s ease;
    }}
    /* ── backup list ── */
    .bkp-sched {{ margin-bottom: 0.35rem; }}
    .bkp-list {{ display: flex; flex-direction: column; gap: 0.2rem; }}
    .bkp-row {{
      display: grid;
      grid-template-columns: 3.5rem 1fr auto auto auto auto;
      align-items: center; gap: 0.4rem;
      padding: 0.28rem 0.1rem;
      border-top: 1px solid rgba(212,200,180,0.5);
      font-size: 0.82rem;
    }}
    .bkp-list .bkp-row:first-child {{ border-top: none; }}
    .bkp-age {{ color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }}
    .bkp-src {{ font-weight: 500; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
    .bkp-st {{ display: flex; align-items: center; gap: 0.25rem; flex-wrap: wrap; white-space: nowrap; }}
    .bkp-size {{ color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; min-width: 4.75rem; text-align: right; }}
    .bkp-snap {{ font-family: monospace; font-size: 0.75rem; color: var(--muted); }}
    .bkp-act {{ justify-self: end; display: flex; gap: 0.3rem; flex-wrap: wrap; }}
    .bkp-note {{ font-size: 0.75rem; display: block; }}
    /* ── cluster / units tables ── */
    table {{ width: 100%; border-collapse: collapse; font-size: 0.83rem; }}
    th, td {{
      padding: 0.35rem 0.4rem; text-align: left;
      border-top: 1px solid rgba(212,200,180,0.5); vertical-align: middle;
    }}
    th {{
      border-top: none; color: var(--muted);
      font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.07em;
    }}
    .idx {{ width: 1.5rem; }}
    .host-nm {{ font-weight: 600; }}
    .host-nm .badge {{ margin-left: 0.3rem; vertical-align: middle; }}
    /* ── events ── */
    .events-pre {{
      font-family: monospace; font-size: 0.78rem; line-height: 1.55;
      background: #1a211a; color: #dff2dc;
      padding: 0.75rem; border-radius: 0.6rem;
      overflow: auto; max-height: 18rem; white-space: pre-wrap; word-break: break-all;
    }}
    /* ── utils ── */
    .muted {{ color: var(--muted); }}
    .small {{ font-size: 0.8rem; }}
    .section {{ }}
    @media (max-width: 600px) {{
      .site-hd {{ flex-direction: column; align-items: flex-start; }}
      .bkp-row {{ grid-template-columns: 3rem 1fr auto; }}
      .bkp-snap, .bkp-st, .bkp-size {{ display: none; }}
    }}
  </style>
</head>
<body>
  <header class="site-hd">
    <div class="brand">
      <span class="cluster-nm">Alanix · {html.escape(self.cluster["name"])}</span>
      <span class="node-nm muted">{html.escape(self.hostname)}</span>
    </div>
    <div class="hd-right">
      {b(role["label"], role["kind"])}
    </div>
  </header>
  <main>
    {admin_bar}
    {ops_banner}
    {services_html}
    {cluster_panel}
    {units_panel}
    {events_panel}
  </main>
  <script>
    (function() {{
      var liveSource = null;
      var pendingHtml = null;
      var reconnectTimer = null;
      var sectionIds = [
        'admin-bar', 'ops-banner', 'services-section',
        'cluster-panel', 'units-panel', 'events-panel'
      ];

      function userIsEditingForm() {{
        var a = document.activeElement;
        return a && (a.matches('input,textarea,select,button') || a.isContentEditable);
      }}

      function captureOpenDetails() {{
        var s = new Set();
        document.querySelectorAll('details[data-detail-key]').forEach(function(el) {{
          if (el.open) s.add(el.getAttribute('data-detail-key'));
        }});
        return s;
      }}

      function restoreOpenDetails(s) {{
        document.querySelectorAll('details[data-detail-key]').forEach(function(el) {{
          var k = el.getAttribute('data-detail-key');
          if (k && s.has(k)) el.open = true;
        }});
      }}

      function preserveScrolls() {{
        var m = {{}};
        document.querySelectorAll('[data-preserve-scroll]').forEach(function(el) {{
          if (el.id) m[el.id] = el.scrollTop;
        }});
        return m;
      }}

      function restoreScrolls(m) {{
        Object.keys(m).forEach(function(id) {{
          var el = document.getElementById(id);
          if (el) el.scrollTop = m[id];
        }});
      }}

      function replaceSectionFromDoc(id, doc) {{
        var next = doc.getElementById(id);
        var cur = document.getElementById(id);
        if (!next && !cur) return;
        if (!next && cur) {{ cur.remove(); return; }}
        if (next && !cur) {{
          var anchor = document.querySelector('main');
          if (anchor) anchor.appendChild(next.cloneNode(true));
          return;
        }}
        cur.replaceWith(next.cloneNode(true));
      }}

      function syncServicesSection(doc) {{
        var cur = document.getElementById('services-section');
        var next = doc.getElementById('services-section');
        if (!cur || !next) {{ replaceSectionFromDoc('services-section', doc); return; }}
        var curGrid = cur.querySelector('.services');
        var nextGrid = next.querySelector('.services');
        if (!curGrid || !nextGrid) {{ replaceSectionFromDoc('services-section', doc); return; }}
        var byName = {{}};
        Array.from(curGrid.querySelectorAll('.svc-card[data-service-name]')).forEach(function(c) {{
          byName[c.getAttribute('data-service-name')] = c;
        }});
        var nextCards = Array.from(nextGrid.children);
        nextCards.forEach(function(nc, idx) {{
          if (!curGrid) return;
          if (!nc.classList.contains('svc-card')) {{ replaceSectionFromDoc('services-section', doc); curGrid = null; return; }}
          var name = nc.getAttribute('data-service-name');
          var cc = byName[name];
          if (!cc) {{
            cc = nc.cloneNode(true);
          }} else if (cc.outerHTML !== nc.outerHTML) {{
            cc.replaceWith(nc.cloneNode(true));
            cc = curGrid.querySelector('.svc-card[data-service-name="' + name + '"]');
          }}
          var slot = curGrid.children[idx] || null;
          if (cc !== slot) curGrid.insertBefore(cc, slot);
        }});
        if (!curGrid) return;
        Array.from(curGrid.querySelectorAll('.svc-card[data-service-name]')).forEach(function(c) {{
          if (!nextGrid.querySelector('.svc-card[data-service-name="' + c.getAttribute('data-service-name') + '"]')) c.remove();
        }});
      }}

      function applyHtml(htmlText) {{
        if (!htmlText) return;
        if (document.hidden || userIsEditingForm()) {{ pendingHtml = htmlText; return; }}
        try {{
          var y = window.scrollY;
          var scrolls = preserveScrolls();
          var open = captureOpenDetails();
          var doc = new DOMParser().parseFromString(htmlText, 'text/html');
          sectionIds.forEach(function(id) {{
            if (id === 'services-section') syncServicesSection(doc);
            else replaceSectionFromDoc(id, doc);
          }});
          restoreOpenDetails(open);
          requestAnimationFrame(function() {{ restoreScrolls(scrolls); window.scrollTo(0, y); }});
        }} catch(e) {{}}
      }}

      function flushPending() {{
        if (!pendingHtml || document.hidden || userIsEditingForm()) return;
        var t = pendingHtml; pendingHtml = null; applyHtml(t);
      }}

      document.addEventListener('focusout', function() {{ requestAnimationFrame(flushPending); }}, true);
      document.addEventListener('visibilitychange', function() {{ if (!document.hidden) flushPending(); }});

      function connect() {{
        if (!window.EventSource) return;
        if (liveSource) liveSource.close();
        liveSource = new EventSource('/api/events');
        liveSource.addEventListener('update', function(ev) {{
          try {{ applyHtml(JSON.parse(ev.data || '{{}}').html || ''); }} catch(e) {{}}
        }});
        liveSource.onerror = function() {{
          if (liveSource) {{ liveSource.close(); liveSource = null; }}
          clearTimeout(reconnectTimer);
          reconnectTimer = setTimeout(connect, 3000);
        }};
      }}
      connect();
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

        last_sent_seq = -1
        last_ping_at = time.time()

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

                now = time.time()
                if new_ready:
                    session = self.current_session()
                    payload = json.dumps(
                        {
                            "updatedAt": state.get("generatedAt") or iso_timestamp(),
                            "html": self.dashboard.render_html(state, session=session),
                        }
                    ).encode("utf-8")
                    self.wfile.write(b"event: update\n")
                    self.wfile.write(b"data: ")
                    self.wfile.write(payload)
                    self.wfile.write(b"\n\n")
                    self.wfile.flush()
                    last_sent_seq = seq
                    last_ping_at = now
                else:
                    self.wfile.write(b"event: ping\ndata: {}\n\n")
                    self.wfile.flush()
                    last_ping_at = now
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/events":
            self.handle_event_stream()
            return

        session = self.current_session()
        if path == "/api/status":
            state = self.dashboard.collect()
            payload = json.dumps(state, indent=2).encode("utf-8")
            self.respond_bytes(200, payload, "application/json; charset=utf-8")
            return

        if path in {"/", ""}:
            with self.dashboard._state_cond:
                state = self.dashboard._cached_state
            if state is None:
                state = self.dashboard.collect()
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
