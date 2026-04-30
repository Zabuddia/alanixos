#!/usr/bin/env python3

import base64
import collections
import concurrent.futures
import glob
import hashlib
import json
import math
import os
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def log(message: str) -> None:
    print(f"[alanix-cluster] {message}", flush=True)


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


def lease_id_arg(value: int) -> str:
    return format(value, "x")


def summarize_error(message: str, *, limit: int = 400) -> str:
    flattened = " ".join(message.split())
    if len(flattened) <= limit:
        return flattened
    return flattened[: limit - 3] + "..."


def summarize_etcdctl_output(output: str, *, limit: int = 180) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    parsed_errors = []

    for line in lines:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        error = payload.get("error")
        if error:
            parsed_errors.append(error)

    if parsed_errors:
        unique_errors = []
        for error in parsed_errors:
            if error not in unique_errors:
                unique_errors.append(error)
        return summarize_error("; ".join(unique_errors), limit=limit)

    return summarize_error(output or "no etcdctl output", limit=limit)


def format_duration(seconds: float) -> str:
    seconds = max(0.0, seconds)
    if seconds < 1.0:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 10.0:
        return f"{seconds:.1f}s"
    if seconds < 60.0:
        return f"{seconds:.0f}s"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {remainder}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    if value is None:
        value = now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def atomic_write_json(
    path: Path,
    payload,
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    mode: int | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        existing_stat = path.stat()
    except FileNotFoundError:
        existing_stat = None

    if existing_stat is not None:
        if owner_uid is None:
            owner_uid = existing_stat.st_uid
        if owner_gid is None:
            owner_gid = existing_stat.st_gid
        if mode is None:
            mode = stat.S_IMODE(existing_stat.st_mode)

    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            temp_path = Path(handle.name)
        if mode is not None:
            os.chmod(temp_path, mode)
        if owner_uid is not None or owner_gid is not None:
            os.chown(
                temp_path,
                owner_uid if owner_uid is not None else -1,
                owner_gid if owner_gid is not None else -1,
            )
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink(missing_ok=True)


def remove_path(path: str) -> None:
    if not os.path.lexists(path):
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
        return
    os.remove(path)


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


def parse_restic_progress_line(line: str) -> dict | None:
    stripped = line.strip()
    if not stripped:
        return None

    if stripped.startswith("{"):
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError:
            payload = None
        if payload:
            message_type = payload.get("message_type")
            if message_type == "status":
                return {
                    "kind": "progress",
                    "percent": float(payload.get("percent_done", 0.0)) * 100.0,
                    "filesDone": payload.get("files_done"),
                    "totalFiles": payload.get("total_files"),
                    "bytesDone": payload.get("bytes_done"),
                    "totalBytes": payload.get("total_bytes"),
                }
            if message_type == "summary":
                return {
                    "kind": "summary",
                    "summary": payload,
                }

    copy_match = re.search(
        r"\]\s+([0-9]+(?:\.[0-9]+)?)%\s+([0-9]+)\s*/\s*([0-9]+)\s+packs copied",
        stripped,
    )
    if copy_match:
        return {
            "kind": "progress",
            "percent": float(copy_match.group(1)),
            "packsDone": int(copy_match.group(2)),
            "totalPacks": int(copy_match.group(3)),
        }

    if stripped.startswith("snapshot ") and stripped.endswith(" saved"):
        return {
            "kind": "summary",
            "summary": {"message": stripped},
        }

    return None


def parse_prep_progress_line(line: str) -> dict | None:
    stripped = line.strip()
    if not stripped:
        return None

    step_match = re.match(r"^ALANIX-PROGRESS STEP ([0-9]+) ([0-9]+) (.+)$", stripped)
    if step_match:
        return {
            "kind": "step",
            "stepIndex": max(1, int(step_match.group(1))),
            "stepTotal": max(1, int(step_match.group(2))),
            "label": step_match.group(3).strip(),
        }

    rsync_match = re.match(r"^\s*([0-9][0-9,]*)\s+([0-9]+)%\s+", line)
    if rsync_match:
        bytes_done = int(rsync_match.group(1).replace(",", ""))
        percent = float(rsync_match.group(2))
        total_bytes = None
        if 0.0 < percent <= 100.0:
            total_bytes = max(bytes_done, int(round(bytes_done * 100.0 / percent)))
        return {
            "kind": "progress",
            "bytesDone": bytes_done,
            "totalBytes": total_bytes,
            "percent": percent,
        }

    return None


class EtcdUnavailable(RuntimeError):
    pass


class Controller:
    HA_MODE = "ha"
    STANDALONE_MODES = {
        "planned-standalone",
        "emergency-standalone",
        "resume-pending",
        "resume-seeding",
    }
    RUNTIME_MODES = STANDALONE_MODES | {HA_MODE}

    def __init__(self, config_path: str) -> None:
        with open(config_path, "r", encoding="utf-8") as handle:
            self.config = json.load(handle)

        self.cluster = self.config["cluster"]
        self.services = self.config["services"]
        self.hostname = self.cluster["hostname"]
        self.leader_key = self.cluster["leaderKey"]
        self.runtime_mode_key = self.cluster.get("runtimeModeKey", f"{self.leader_key.rsplit('/', 1)[0]}/runtime-mode")
        self.runtime_mode_ack_prefix = self.cluster.get(
            "runtimeModeAckPrefix",
            f"{self.leader_key.rsplit('/', 1)[0]}/runtime-mode-acks",
        ).rstrip("/")
        self.target = self.cluster["activeTarget"]
        self.members = self.cluster.get("members") or self.cluster.get("priority", [])
        self.voters = self.cluster.get("voters") or self.members
        self.peer_mode_probe_urls = self.cluster.get("modeProbeUrls", {})
        self.peer_mode_probe_timeout = float(self.cluster.get("modeProbeTimeoutSeconds", 2.0))
        self.mode_ack_timeout = float(parse_duration_seconds(self.cluster.get("modeAckTimeout", "2m")))
        self.mode_ack_poll_interval = float(parse_duration_seconds(self.cluster.get("modeAckPollInterval", "2s")))
        self.repo_user = self.cluster["backup"]["repoUser"]
        repo_account = pwd.getpwnam(self.repo_user)
        self.repo_uid = repo_account.pw_uid
        self.repo_gid = repo_account.pw_gid
        self.password_file = self.cluster["backup"]["passwordFile"]
        self.max_concurrent_backups = max(1, int(self.cluster["backup"].get("maxConcurrent", 2)))
        self.min_backup_free_space_bytes = int(self.cluster["backup"].get("minFreeSpaceBytes", 0))
        self.endpoints = self.cluster["endpoints"]
        self.etcd_dial_timeout = self.cluster["etcd"].get("dialTimeout", "1s")
        self.etcd_command_timeout = self.cluster["etcd"].get("commandTimeout", "3s")
        self.etcd_endpoint_index = 0
        self.etcd_endpoint_lock = threading.Lock()
        self.bootstrap_host = self.cluster["bootstrapHost"]
        self.priority = self.cluster["priority"]
        self.priority_index = self.priority.index(self.hostname)
        self.lease_ttl = int(parse_duration_seconds(self.cluster["etcd"]["leaseTtl"]))
        self.acquisition_step = parse_duration_seconds(self.cluster["etcd"]["acquisitionStep"])
        self.cluster_data_dir = Path(self.cluster["backup"]["repoBaseDir"]) / self.cluster["name"]
        self.runtime_mode_file = Path(
            self.cluster.get("runtimeModeFile")
            or "/var/lib/alanix-cluster/runtime-mode.json"
        )
        self.runtime_dir = Path(os.environ.get("ALANIX_CLUSTER_RUNTIME_DIR", "/run/alanix-cluster"))
        self.admin_queue_dir = self.runtime_dir / "admin-queue"
        self.admin_inflight_dir = self.runtime_dir / "admin-inflight"
        self.runtime_state_file = self.runtime_dir / "controller-state.json"
        self.runtime_state_lock = threading.Lock()
        self.service_operations = {name: None for name in self.services}
        self.operation_history = collections.deque(maxlen=50)
        self.last_runtime_state_signature = None

        self.keepalive_proc = None
        self.keepalive_reader = None
        self.keepalive_last_ack_at = None
        self.keepalive_output = collections.deque(maxlen=20)
        self.keepalive_lock = threading.Lock()
        self.lease_id = None
        self.leader_revision = None
        self.last_leader_absent_at = None
        self.last_active_etcd_warning_at = 0.0
        self.last_passive_etcd_warning_at = 0.0
        self.last_lease_grant_warning_at = 0.0
        self.next_backup_at = {name: 0.0 for name in self.services}
        self.backup_executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=self.max_concurrent_backups,
            thread_name_prefix="alanix-backup",
        )
        self.running_backups = {}
        self.backup_generation = 0
        self.backup_generation_lock = threading.Lock()
        self.resume_seed_generation = None
        self.last_runtime_mode_warning_at = 0.0
        self.last_peer_guard_warning_at = 0.0
        self.last_mode_ack_warning_at = 0.0
        self.admin_executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="alanix-admin",
        )
        self.running_admin_operation = None

        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.admin_queue_dir.mkdir(parents=True, exist_ok=True)
        self.admin_inflight_dir.mkdir(parents=True, exist_ok=True)
        self.requeue_stale_admin_requests()
        self.write_runtime_state(force=True)

    def run(self, cmd, *, check=True, input_text=None, env=None):
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        proc = subprocess.run(
            cmd,
            check=False,
            text=True,
            input=input_text,
            capture_output=True,
            env=merged_env,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(
                f"command failed ({proc.returncode}): {' '.join(shlex.quote(part) for part in cmd)}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            )
        return proc

    def run_stream(self, cmd, *, check=True, input_text=None, env=None, on_line=None):
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if input_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=merged_env,
            bufsize=1,
        )

        if input_text is not None and proc.stdin is not None:
            proc.stdin.write(input_text)
            proc.stdin.close()

        output_lines = []
        assert proc.stdout is not None
        for raw_line in proc.stdout:
            line = raw_line.rstrip("\n")
            output_lines.append(line)
            if on_line is not None:
                on_line(line)

        proc.wait()
        stdout = "\n".join(output_lines)
        if check and proc.returncode != 0:
            raise RuntimeError(
                f"command failed ({proc.returncode}): {' '.join(shlex.quote(part) for part in cmd)}\n"
                f"stdout:\n{stdout}\n"
                "stderr:\n"
            )

        return subprocess.CompletedProcess(cmd, proc.returncode, stdout, "")

    def current_etcd_endpoint(self):
        with self.etcd_endpoint_lock:
            return self.endpoints[self.etcd_endpoint_index]

    def ordered_etcd_endpoints(self):
        with self.etcd_endpoint_lock:
            start = self.etcd_endpoint_index
        return [
            (index % len(self.endpoints), self.endpoints[index % len(self.endpoints)])
            for index in range(start, start + len(self.endpoints))
        ]

    def mark_etcd_endpoint_good(self, index):
        with self.etcd_endpoint_lock:
            self.etcd_endpoint_index = index

    def etcdctl(self, args, *, check=True, input_text=None):
        errors = []
        last_proc = None
        last_cmd = None

        for index, endpoint in self.ordered_etcd_endpoints():
            cmd = [
                "etcdctl",
                f"--dial-timeout={self.etcd_dial_timeout}",
                f"--command-timeout={self.etcd_command_timeout}",
                f"--endpoints={endpoint}",
                "--write-out=json",
            ] + args
            proc = self.run(cmd, check=False, input_text=input_text)
            if proc.returncode == 0:
                self.mark_etcd_endpoint_good(index)
                return proc

            last_proc = proc
            last_cmd = cmd
            errors.append(f"{endpoint}: {summarize_etcdctl_output(proc.stderr or proc.stdout)}")

        stderr = "all etcd endpoints failed: " + "; ".join(errors)
        if last_proc is None:
            last_cmd = ["etcdctl"] + args
            last_proc = subprocess.CompletedProcess(last_cmd, 1, "", stderr)
        else:
            last_proc = subprocess.CompletedProcess(last_cmd, last_proc.returncode, last_proc.stdout, stderr)

        if check:
            raise RuntimeError(
                f"command failed ({last_proc.returncode}): {' '.join(shlex.quote(part) for part in last_cmd)}\n"
                f"stdout:\n{last_proc.stdout}\n"
                f"stderr:\n{last_proc.stderr}"
            )

        return last_proc

    def log_every(self, attr, interval, message):
        now = time.monotonic()
        if now - getattr(self, attr) >= interval:
            log(message)
            setattr(self, attr, now)

    def run_as_backup_user(self, args, *, check=True, input_text=None):
        cmd = ["runuser", "-u", self.repo_user, "--"] + args
        env = {
            "RESTIC_PASSWORD_FILE": self.password_file,
        }
        return self.run(cmd, check=check, input_text=input_text, env=env)

    def run_as_backup_user_stream(self, args, *, check=True, input_text=None, env=None, on_line=None):
        cmd = ["runuser", "-u", self.repo_user, "--"] + args
        merged_env = {
            "RESTIC_PASSWORD_FILE": self.password_file,
        }
        if env:
            merged_env.update(env)
        return self.run_stream(cmd, check=check, input_text=input_text, env=merged_env, on_line=on_line)

    def get_leader(self):
        proc = self.etcdctl(["get", self.leader_key], check=False)
        if proc.returncode != 0:
            detail = summarize_error(proc.stderr or proc.stdout or "no etcdctl output")
            raise EtcdUnavailable(f"leader query failed ({proc.returncode}): {detail}")
        try:
            payload = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise EtcdUnavailable(f"leader query returned invalid json: {summarize_error(str(exc))}") from exc
        kvs = payload.get("kvs", [])
        if not kvs:
            return None
        kv = kvs[0]
        return {
            "host": decode_etcd_string(kv["value"]),
            "lease_id": parse_lease_id(kv.get("lease")),
            "create_revision": int(kv["create_revision"]),
            "mod_revision": int(kv["mod_revision"]),
        }

    def normalize_runtime_mode(self, payload, *, source="unknown"):
        if not isinstance(payload, dict):
            payload = {}
        mode = payload.get("mode") or self.HA_MODE
        if mode not in self.RUNTIME_MODES:
            mode = self.HA_MODE
        normalized = dict(payload)
        normalized["mode"] = mode
        normalized["source"] = source
        if mode != self.HA_MODE:
            normalized.setdefault("standaloneHost", payload.get("keeper") or self.hostname)
            normalized.setdefault("generation", str(int(time.time())))
        return normalized

    def local_ha_mode(self):
        return {
            "mode": self.HA_MODE,
            "source": "default",
        }

    def read_local_runtime_mode(self):
        if not self.runtime_mode_file.exists():
            return self.local_ha_mode()
        try:
            payload = json.loads(self.runtime_mode_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            self.log_every(
                "last_runtime_mode_warning_at",
                30.0,
                f"cannot read local runtime mode marker; treating node as passive: {summarize_error(str(exc))}",
            )
            return {
                "mode": "emergency-standalone",
                "source": "local-error",
                "standaloneHost": "unknown",
                "generation": "unknown",
                "reason": "corrupt local runtime mode marker",
            }
        return self.normalize_runtime_mode(payload, source="local")

    def write_local_runtime_mode(self, payload):
        mode_state = self.normalize_runtime_mode(payload, source="local")
        if mode_state["mode"] == self.HA_MODE:
            self.runtime_mode_file.unlink(missing_ok=True)
            return mode_state
        stored = dict(mode_state)
        stored.pop("source", None)
        stored.setdefault("updatedAt", iso_timestamp())
        atomic_write_json(self.runtime_mode_file, stored, mode=0o644)
        return self.normalize_runtime_mode(stored, source="local")

    def clear_local_runtime_mode(self):
        self.runtime_mode_file.unlink(missing_ok=True)

    def get_etcd_runtime_mode(self):
        proc = self.etcdctl(["get", self.runtime_mode_key], check=False)
        if proc.returncode != 0:
            detail = summarize_error(proc.stderr or proc.stdout or "no etcdctl output")
            raise EtcdUnavailable(f"runtime mode query failed ({proc.returncode}): {detail}")
        try:
            payload = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise EtcdUnavailable(f"runtime mode query returned invalid json: {summarize_error(str(exc))}") from exc
        kvs = payload.get("kvs", [])
        if not kvs:
            return self.local_ha_mode()
        raw_value = decode_etcd_string(kvs[0]["value"])
        try:
            mode_payload = json.loads(raw_value)
        except json.JSONDecodeError as exc:
            raise EtcdUnavailable(f"runtime mode value is invalid json: {summarize_error(str(exc))}") from exc
        return self.normalize_runtime_mode(mode_payload, source="etcd")

    def put_etcd_runtime_mode(self, payload):
        stored = dict(self.normalize_runtime_mode(payload, source="etcd"))
        stored.pop("source", None)
        stored.setdefault("updatedAt", iso_timestamp())
        self.etcdctl(["put", self.runtime_mode_key, json.dumps(stored, sort_keys=True)])
        return self.normalize_runtime_mode(stored, source="etcd")

    def delete_etcd_runtime_mode(self):
        self.etcdctl(["del", self.runtime_mode_key], check=False)

    def mode_ack_key(self, generation, host=None):
        ack_host = host or self.hostname
        return f"{self.runtime_mode_ack_prefix}/{generation}/{ack_host}"

    def ack_runtime_mode(self, mode_state):
        generation = mode_state.get("generation")
        if generation is None:
            return
        ack = {
            "host": self.hostname,
            "mode": mode_state.get("mode"),
            "generation": generation,
            "standaloneHost": mode_state.get("standaloneHost"),
            "acknowledgedAt": iso_timestamp(),
        }
        proc = self.etcdctl(
            ["put", self.mode_ack_key(generation), json.dumps(ack, sort_keys=True)],
            check=False,
        )
        if proc.returncode != 0:
            self.log_every(
                "last_mode_ack_warning_at",
                30.0,
                f"failed to ack runtime mode {mode_state.get('mode')}: {summarize_error(proc.stderr or proc.stdout)}",
            )

    def acked_runtime_mode_hosts(self, generation):
        proc = self.etcdctl(["get", f"{self.runtime_mode_ack_prefix}/{generation}/", "--prefix"], check=False)
        if proc.returncode != 0:
            raise EtcdUnavailable(f"runtime mode ack query failed: {summarize_error(proc.stderr or proc.stdout)}")
        try:
            payload = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise EtcdUnavailable(f"runtime mode ack query returned invalid json: {summarize_error(str(exc))}") from exc
        hosts = set()
        for kv in payload.get("kvs", []):
            key = decode_etcd_string(kv.get("key", ""))
            if key:
                hosts.add(key.rsplit("/", 1)[-1])
        return hosts

    def wait_for_runtime_mode_acks(self, mode_state, *, required_hosts=None, timeout=None):
        generation = mode_state.get("generation")
        if generation is None:
            return
        required = set(required_hosts or self.voters)
        deadline = time.monotonic() + (self.mode_ack_timeout if timeout is None else timeout)
        while True:
            self.ack_runtime_mode(mode_state)
            hosts = self.acked_runtime_mode_hosts(generation)
            missing = sorted(required - hosts)
            if not missing:
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    f"timed out waiting for runtime mode acknowledgements from: {', '.join(missing)}"
                )
            self.set_admin_operation_state(
                {
                    "action": mode_state.get("mode"),
                    "service": "",
                    "requestedBy": mode_state.get("requestedBy"),
                    "submittedAt": mode_state.get("requestedAt"),
                    "startedAt": mode_state.get("updatedAt") or iso_timestamp(),
                    "status": "waiting",
                    "message": f"waiting for acknowledgements: {', '.join(missing)}",
                }
            )
            time.sleep(self.mode_ack_poll_interval)

    def peer_mode_probe(self):
        results = {}
        for peer, urls in sorted(self.peer_mode_probe_urls.items()):
            if peer == self.hostname:
                continue
            peer_results = []
            for url in urls:
                try:
                    with urllib.request.urlopen(url, timeout=self.peer_mode_probe_timeout) as response:
                        payload = json.loads(response.read().decode("utf-8"))
                    mode_state = self.normalize_runtime_mode(payload.get("modeState") or payload, source=f"peer:{peer}")
                    peer_results.append({"url": url, "ok": True, "modeState": mode_state})
                    break
                except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
                    peer_results.append({"url": url, "ok": False, "error": summarize_error(str(exc), limit=160)})
            results[peer] = peer_results
        return results

    def peer_guard_mode(self):
        probes = self.peer_mode_probe()
        failed = []
        for peer, attempts in probes.items():
            ok_attempt = next((item for item in attempts if item.get("ok")), None)
            if ok_attempt is None:
                failed.append(peer)
                continue
            mode_state = ok_attempt["modeState"]
            if mode_state.get("mode") != self.HA_MODE:
                return mode_state, probes
        if failed:
            return {
                "mode": "peer-unknown",
                "source": "peer-guard",
                "failedPeers": failed,
            }, probes
        return self.local_ha_mode(), probes

    def effective_runtime_mode(self):
        try:
            mode_state = self.get_etcd_runtime_mode()
        except EtcdUnavailable:
            mode_state = self.read_local_runtime_mode()
            if mode_state.get("mode") == self.HA_MODE:
                peer_mode, _ = self.peer_guard_mode()
                if peer_mode.get("mode") != self.HA_MODE:
                    if peer_mode.get("mode") == "peer-unknown":
                        return peer_mode
                    marker = dict(peer_mode)
                    marker["reason"] = "learned from peer dashboard mode probe"
                    return self.write_local_runtime_mode(marker)
            return mode_state

        if mode_state.get("mode") == self.HA_MODE:
            local_mode = self.read_local_runtime_mode()
            if mode_state.get("source") == "default" and local_mode.get("mode") != self.HA_MODE:
                return local_mode
            self.clear_local_runtime_mode()
            if mode_state.get("generation") is not None:
                self.ack_runtime_mode(mode_state)
            return mode_state

        self.write_local_runtime_mode(mode_state)
        self.ack_runtime_mode(mode_state)
        return mode_state

    def grant_lease(self):
        payload = json.loads(self.etcdctl(["lease", "grant", str(self.lease_ttl)]).stdout)
        return parse_lease_id(payload["ID"])

    def revoke_lease(self, lease_id):
        self.etcdctl(["lease", "revoke", lease_id_arg(lease_id)], check=False)

    def acquire_lease(self):
        try:
            lease_id = self.grant_lease()
        except Exception as exc:
            self.log_every(
                "last_lease_grant_warning_at",
                30.0,
                f"cannot acquire leadership because etcd lease grant failed: {summarize_error(str(exc))}",
            )
            return None
        txn = (
            f'version("{self.leader_key}") = "0"\n\n'
            f"put {self.leader_key} {self.hostname} --lease={lease_id_arg(lease_id)}\n\n"
            f"get {self.leader_key}\n\n"
        )
        txn_proc = self.etcdctl(["txn", "-i"], check=False, input_text=txn)
        if txn_proc.returncode != 0:
            log(f"failed lease acquisition transaction: {txn_proc.stderr.strip() or txn_proc.stdout.strip()}")
        try:
            leader = self.get_leader()
        except EtcdUnavailable as exc:
            log(f"leader check after lease acquisition failed: {summarize_error(str(exc))}")
            self.revoke_lease(lease_id)
            return None
        if leader and leader["host"] == self.hostname and leader["lease_id"] == lease_id:
            return leader
        self.revoke_lease(lease_id)
        return None

    def start_keepalive(self, lease_id):
        self.stop_keepalive()
        endpoint = self.current_etcd_endpoint()
        with self.keepalive_lock:
            self.keepalive_last_ack_at = time.monotonic()
            self.keepalive_output.clear()
        cmd = [
            "etcdctl",
            f"--endpoints={endpoint}",
            "lease",
            "keep-alive",
            lease_id_arg(lease_id),
        ]
        env = os.environ.copy()
        self.keepalive_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
        self.keepalive_reader = threading.Thread(
            target=self.read_keepalive_output,
            args=(self.keepalive_proc,),
            daemon=True,
        )
        self.keepalive_reader.start()
        log(f"started lease keepalive via {endpoint}")

    def read_keepalive_output(self, proc):
        if proc.stdout is None:
            return
        for raw_line in proc.stdout:
            line = raw_line.strip()
            if not line:
                continue
            lower_line = line.lower()
            with self.keepalive_lock:
                self.keepalive_output.append(line)
                if proc is self.keepalive_proc and ("keepalived" in lower_line or '"ttl"' in lower_line):
                    self.keepalive_last_ack_at = time.monotonic()

    def keepalive_ack_age(self):
        with self.keepalive_lock:
            if self.keepalive_last_ack_at is None:
                return None
            return time.monotonic() - self.keepalive_last_ack_at

    def recent_keepalive_output(self):
        with self.keepalive_lock:
            return " | ".join(self.keepalive_output)

    def stop_keepalive(self):
        if self.keepalive_proc is not None:
            self.keepalive_proc.terminate()
            try:
                self.keepalive_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.keepalive_proc.kill()
            self.keepalive_proc = None
            self.keepalive_reader = None

    def target_is_active(self):
        return self.run(["systemctl", "is-active", "--quiet", self.target], check=False).returncode == 0

    def managed_units(self):
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

    def any_managed_unit_active(self):
        return any(
            self.run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0
            for unit in self.managed_units()
        )

    def start_target(self):
        log(f"starting target {self.target}")
        self.run(["systemctl", "start", self.target])

    def stop_target(self):
        units = self.managed_units()
        log(f"stopping {len(units)} managed unit(s): {', '.join(units)}")
        proc = self.run(["systemctl", "stop"] + units, check=False)
        if proc.returncode != 0:
            log(f"stop target exited {proc.returncode}: {summarize_error(proc.stderr or proc.stdout or '')}")

    def demote(self, reason):
        log(f"demoting: {reason}")
        self.advance_backup_generation()
        self.stop_keepalive()
        self.stop_target()
        if self.lease_id is not None:
            self.revoke_lease(self.lease_id)
        self.lease_id = None
        self.leader_revision = None
        self.last_leader_absent_at = None

    def release_leadership_keep_workloads(self, reason):
        if self.lease_id is not None:
            log(f"releasing cluster lease but keeping workloads active: {reason}")
            self.advance_backup_generation()
        self.stop_keepalive()
        if self.lease_id is not None:
            self.revoke_lease(self.lease_id)
        self.lease_id = None
        self.leader_revision = None
        self.last_leader_absent_at = None

    def apply_runtime_mode(self, mode_state):
        mode = mode_state.get("mode") or self.HA_MODE
        if mode == self.HA_MODE:
            return False

        if mode == "peer-unknown":
            self.log_every(
                "last_peer_guard_warning_at",
                30.0,
                "runtime mode peer guard is holding this node passive because peer dashboard mode could not be confirmed",
            )
            if self.any_managed_unit_active():
                self.stop_target()
            self.stop_keepalive()
            self.lease_id = None
            self.leader_revision = None
            return True

        standalone_host = mode_state.get("standaloneHost")
        if standalone_host == self.hostname:
            self.write_local_runtime_mode(mode_state)
            self.release_leadership_keep_workloads(f"runtime mode {mode}")
            if not self.target_is_active():
                self.start_target()
        else:
            self.write_local_runtime_mode(mode_state)
            if self.lease_id is not None or self.any_managed_unit_active():
                self.demote(f"runtime mode {mode} belongs to {standalone_host}")
            else:
                self.stop_keepalive()
                self.lease_id = None
                self.leader_revision = None
        return True

    def advance_backup_generation(self):
        with self.backup_generation_lock:
            self.backup_generation += 1
            return self.backup_generation

    def backup_generation_is_current(self, generation):
        with self.backup_generation_lock:
            return generation == self.backup_generation and (
                self.lease_id is not None or generation == self.resume_seed_generation
            )

    def ensure_backup_generation_current(self, generation, service_name):
        if not self.backup_generation_is_current(generation):
            raise RuntimeError(f"{service_name}: backup cancelled because leadership changed")

    def service_manifest_globs(self, service_name):
        service = self.services[service_name]
        return [glob_pattern for glob_pattern in service.get("manifestGlobs", []) if glob_pattern]

    def service_pin_dir(self, service_name):
        return self.cluster_data_dir / service_name / "pins"

    def pin_record_path(self, service_name, manifest_path):
        return self.service_pin_dir(service_name) / f"{manifest_pin_id(manifest_path)}.json"

    def read_pin_record(self, service_name, manifest_path):
        pin_path = self.pin_record_path(service_name, manifest_path)
        if not pin_path.exists():
            return None
        try:
            return json.loads(pin_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return None

    def write_runtime_state(self, *, force=False):
        local_mode = self.read_local_runtime_mode()
        with self.runtime_state_lock:
            payload = {
                "hostname": self.hostname,
                "leaseId": self.lease_id,
                "leaderRevision": self.leader_revision,
                "isLeader": self.lease_id is not None,
                "runtimeMode": local_mode,
                "backupSlots": {
                    "used": len(self.running_backups),
                    "max": self.max_concurrent_backups,
                },
                "runningBackups": [
                    {
                        "service": service_name,
                        "origin": backup.get("origin", "automatic"),
                        "requestedBy": backup.get("requestedBy"),
                    }
                    for service_name, backup in sorted(self.running_backups.items())
                ],
                "serviceOperations": self.service_operations,
                "adminOperation": self.running_admin_operation["state"] if self.running_admin_operation else None,
                "recentOperations": list(self.operation_history),
            }
        signature = json.dumps(payload, sort_keys=True)
        if not force and signature == self.last_runtime_state_signature:
            return
        self.last_runtime_state_signature = signature
        payload_with_timestamp = dict(payload)
        payload_with_timestamp["generatedAt"] = iso_timestamp()
        atomic_write_json(self.runtime_state_file, payload_with_timestamp)

    def start_service_operation(self, service_name, *, action, origin, phase, percent=0.0, requested_by=None):
        operation = {
            "service": service_name,
            "action": action,
            "origin": origin,
            "phase": phase,
            "percent": round(max(0.0, min(100.0, float(percent))), 1),
            "requestedBy": requested_by,
            "startedAt": iso_timestamp(),
            "updatedAt": iso_timestamp(),
        }
        with self.runtime_state_lock:
            self.service_operations[service_name] = operation
        self.write_runtime_state()

    def update_service_operation(self, service_name, **updates):
        with self.runtime_state_lock:
            operation = self.service_operations.get(service_name)
            if operation is None:
                return
            for key, value in updates.items():
                if value is None and key not in {"summary"}:
                    continue
                if key == "percent" and value is not None:
                    operation[key] = round(max(0.0, min(100.0, float(value))), 1)
                else:
                    operation[key] = value
            operation["updatedAt"] = iso_timestamp()
        self.write_runtime_state()

    def clear_service_operation(self, service_name, *, status, message, details=None):
        with self.runtime_state_lock:
            operation = self.service_operations.get(service_name)
            if operation is None:
                history = {
                    "service": service_name,
                    "status": status,
                    "message": message,
                    "completedAt": iso_timestamp(),
                }
            else:
                history = dict(operation)
                history.update(
                    {
                        "status": status,
                        "message": message,
                        "details": details,
                        "completedAt": iso_timestamp(),
                    }
                )
            self.operation_history.appendleft(history)
            self.service_operations[service_name] = None
        self.write_runtime_state()

    def record_operation_history(self, payload):
        with self.runtime_state_lock:
            history = dict(payload)
            history.setdefault("completedAt", iso_timestamp())
            self.operation_history.appendleft(history)
        self.write_runtime_state()

    def set_admin_operation_state(self, payload):
        with self.runtime_state_lock:
            if self.running_admin_operation is not None:
                self.running_admin_operation["state"] = payload
        self.write_runtime_state()

    def requeue_stale_admin_requests(self):
        requeued = []
        for path in sorted(self.admin_inflight_dir.glob("*.json")):
            target = self.admin_queue_dir / path.name
            path.replace(target)
            requeued.append(path.name)
        if requeued:
            log(f"requeued {len(requeued)} stale admin request(s) from previous run: {', '.join(requeued)}")

    def take_next_admin_request(self):
        for path in sorted(self.admin_queue_dir.glob("*.json")):
            inflight_path = self.admin_inflight_dir / path.name
            try:
                path.replace(inflight_path)
            except FileNotFoundError:
                continue
            try:
                payload = json.loads(inflight_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                msg = f"invalid admin request {path.name}: {summarize_error(str(exc))}"
                log(f"dropping corrupt admin request: {msg}")
                inflight_path.unlink(missing_ok=True)
                self.record_operation_history(
                    {
                        "action": "admin-request",
                        "status": "failed",
                        "message": msg,
                    }
                )
                continue
            payload["_path"] = str(inflight_path)
            return payload
        return None

    def complete_admin_request_file(self, request):
        request_path = Path(request["_path"])
        request_path.unlink(missing_ok=True)

    def restic_progress_updater(self, service_name, *, phase, base_percent, percent_span, extra=None):
        def handle(line):
            progress = parse_restic_progress_line(line)
            if progress is None:
                return
            if progress["kind"] == "progress":
                percent = base_percent + percent_span * (progress.get("percent", 0.0) / 100.0)
                update = {
                    "phase": phase,
                    "percent": percent,
                    "progress": progress,
                }
                if extra:
                    update.update(extra)
                self.update_service_operation(service_name, **update)
            elif progress["kind"] == "summary":
                update = {
                    "phase": phase,
                    "percent": base_percent + percent_span,
                    "summary": progress.get("summary"),
                }
                if extra:
                    update.update(extra)
                self.update_service_operation(service_name, **update)

        return handle

    def prep_progress_updater(self, service_name, *, phase, base_percent, percent_span):
        state = {
            "stepIndex": 1,
            "stepTotal": 1,
            "label": phase,
        }

        def overall_percent(step_fraction: float) -> float:
            step_total = max(1, int(state["stepTotal"]))
            step_index = min(max(1, int(state["stepIndex"])), step_total)
            fraction = max(0.0, min(1.0, step_fraction))
            return base_percent + percent_span * (((step_index - 1) + fraction) / step_total)

        def handle(line):
            progress = parse_prep_progress_line(line)
            if progress is None:
                return

            if progress["kind"] == "step":
                state["stepIndex"] = progress["stepIndex"]
                state["stepTotal"] = progress["stepTotal"]
                state["label"] = progress.get("label") or phase
                self.update_service_operation(
                    service_name,
                    phase=state["label"],
                    percent=overall_percent(0.0),
                    progress={
                        "kind": "prep-step",
                        "stepIndex": state["stepIndex"],
                        "stepTotal": state["stepTotal"],
                    },
                )
                return

            if progress["kind"] == "progress":
                self.update_service_operation(
                    service_name,
                    phase=state["label"],
                    percent=overall_percent(progress.get("percent", 0.0) / 100.0),
                    progress={
                        "kind": "prep-progress",
                        "stepIndex": state["stepIndex"],
                        "stepTotal": state["stepTotal"],
                        "bytesDone": progress.get("bytesDone"),
                        "totalBytes": progress.get("totalBytes"),
                        "percent": progress.get("percent"),
                    },
                )

        return handle

    def find_manifest(self, service_name, manifest_path):
        for manifest in self.local_manifests_for_service(service_name):
            if manifest.get("_path") == manifest_path:
                return manifest
        raise RuntimeError(f"{service_name}: manifest not found: {manifest_path}")

    def validate_snapshot_exists(self, repo_path, snapshot_id):
        proc = self.run(
            ["restic", "-r", repo_path, "snapshots", snapshot_id, "--json"],
            env={"RESTIC_PASSWORD_FILE": self.password_file},
        )
        try:
            payload = json.loads(proc.stdout or "[]")
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid restic snapshot response for {repo_path}: {exc}") from exc
        if not payload:
            raise RuntimeError(f"snapshot {snapshot_id} not found in {repo_path}")
        payload.sort(key=lambda item: item.get("time", ""))
        return payload[-1]

    def local_manifests_for_service(self, service_name):
        manifests = []
        seen = set()
        for manifest_glob in self.service_manifest_globs(service_name):
            for path in glob.glob(manifest_glob):
                manifest_path = Path(path)
                if not manifest_path.exists():
                    continue
                manifest_key = str(manifest_path)
                if manifest_key in seen:
                    continue
                seen.add(manifest_key)
                try:
                    data = json.loads(manifest_path.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError) as exc:
                    log(f"skipping unreadable manifest {manifest_path}: {summarize_error(str(exc))}")
                    continue
                data["_path"] = str(manifest_path)
                manifests.append(data)
        return manifests

    def freshest_manifest(self, service_name):
        manifests = self.local_manifests_for_service(service_name)
        if not manifests:
            return None
        manifests.sort(key=lambda item: item.get("completedAt", ""))
        return manifests[-1]

    def manifest_age_seconds(self, manifest):
        if manifest is None:
            return None
        completed_at = datetime.fromisoformat(manifest["completedAt"].replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - completed_at).total_seconds()

    def manifest_is_fresh(self, service_name, manifest):
        if manifest is None:
            return False
        max_age = self.services[service_name].get("maxBackupAge")
        if not max_age:
            return True
        max_age_seconds = parse_duration_seconds(max_age)
        age = self.manifest_age_seconds(manifest)
        return age <= max_age_seconds

    def active_snapshot_path(self, service_name):
        return self.cluster_data_dir / service_name / "active-snapshot.json"

    def read_active_snapshot(self, service_name):
        path = self.active_snapshot_path(service_name)
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            log(f"{service_name}: corrupt active snapshot record, will re-restore: {summarize_error(str(exc))}")
            return None
        except OSError as exc:
            log(f"{service_name}: cannot read active snapshot record, will re-restore: {summarize_error(str(exc))}")
            return None

    def write_active_snapshot(self, service_name, manifest):
        path = self.active_snapshot_path(service_name)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(
                json.dumps({"snapshotId": manifest["snapshotId"]}),
                encoding="utf-8",
            )
            tmp.replace(path)
        except Exception as exc:
            log(f"{service_name}: failed to write active snapshot record; next promotion will re-restore: {summarize_error(str(exc))}")

    def local_recovery_profile(self):
        manifests = {}
        all_fresh = True
        worst_age_seconds = 0.0
        missing_services = []

        for service_name in self.services:
            service = self.services[service_name]
            if service.get("recoveryMode") == "declarative":
                manifests[service_name] = None
                continue

            manifest = self.freshest_manifest(service_name)
            manifests[service_name] = manifest

            if manifest is None:
                all_fresh = False
                missing_services.append(service_name)
                worst_age_seconds = math.inf
                continue

            age_seconds = self.manifest_age_seconds(manifest)
            if age_seconds is None:
                all_fresh = False
                worst_age_seconds = math.inf
                continue

            worst_age_seconds = max(worst_age_seconds, age_seconds)
            if not self.manifest_is_fresh(service_name, manifest):
                all_fresh = False

        return {
            "manifests": manifests,
            "allFresh": all_fresh,
            "worstAgeSeconds": worst_age_seconds,
            "missingServices": missing_services,
        }

    def stale_recovery_wait_seconds(self, worst_age_seconds):
        bucket_step = max(0.25, min(1.0, self.acquisition_step / 2.0))
        priority_tie_step = bucket_step / max(1, len(self.priority) + 1)
        if math.isinf(worst_age_seconds):
            bucket = 60
        else:
            bucket = min(60, int(math.log2(max(1.0, worst_age_seconds))))
        fresh_window = len(self.priority) * self.acquisition_step + 1.0
        return fresh_window + bucket * bucket_step + self.priority_index * priority_tie_step

    def ensure_restic_repo(self, remote_uri):
        check = self.run_as_backup_user(["restic", "-r", remote_uri, "snapshots"], check=False)
        if check.returncode == 0:
            return
        log(f"initializing new restic repo at {remote_uri}")
        self.run_as_backup_user(["restic", "-r", remote_uri, "init"])

    def latest_snapshot_id(self, remote_uri):
        payload = json.loads(
            self.run_as_backup_user(["restic", "-r", remote_uri, "snapshots", "--json"]).stdout or "[]"
        )
        if not payload:
            return None
        payload.sort(key=lambda item: item.get("time", ""))
        return payload[-1]["short_id"]

    def restic_snapshot_size(self, repo_uri: str, snapshot_id: str) -> int | None:
        try:
            proc = self.run_as_backup_user(
                ["restic", "--json", "-r", repo_uri, "stats", "--mode", "restore-size", snapshot_id],
                check=False,
            )
            if proc.returncode != 0:
                return None
            payload = json.loads(proc.stdout or "{}")
            size = payload.get("total_size")
            return int(size) if size is not None else None
        except Exception:
            return None

    def _prune_local_manifests(self, manifest_dir: str, retain_days: int, service_name: str) -> None:
        cutoff = time.time() - retain_days * 86400
        for p in Path(manifest_dir).glob("manifest-*.json"):
            try:
                if p.stat().st_mtime >= cutoff:
                    continue
                if self.read_pin_record(service_name, str(p)) is not None:
                    continue
                p.unlink()
                log(f"pruned old manifest: {p}")
            except OSError:
                pass

    def repo_snapshot_ids(self, repo_path: str) -> list[dict]:
        proc = self.run_as_backup_user(["restic", "-r", repo_path, "snapshots", "--json"], check=False)
        if proc.returncode != 0:
            detail = summarize_error(proc.stderr or proc.stdout or "restic snapshots failed")
            raise RuntimeError(f"cannot list snapshots in {repo_path}: {detail}")

        try:
            payload = json.loads(proc.stdout or "[]")
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid restic snapshot response for {repo_path}: {exc}") from exc

        if not isinstance(payload, list):
            raise RuntimeError(f"invalid restic snapshot payload for {repo_path}")

        snapshots = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            snapshot_id = item.get("id")
            short_id = item.get("short_id")
            if not snapshot_id:
                continue
            snapshots.append({"id": snapshot_id, "short_id": short_id})
        return snapshots

    def repo_manifest_snapshot_ids(self, manifest_dir: Path) -> set[str]:
        keep_ids = set()
        for manifest_path in manifest_dir.glob("manifest-*.json"):
            try:
                payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            snapshot_id = payload.get("snapshotId")
            if snapshot_id:
                keep_ids.add(snapshot_id)
        return keep_ids

    def prune_local_repo_snapshots(self, service_name: str, repo_path: str, keep_ids: set[str]) -> int:
        snapshots = self.repo_snapshot_ids(repo_path)
        delete_ids = []
        for snapshot in snapshots:
            snapshot_id = snapshot["id"]
            short_id = snapshot.get("short_id")
            if snapshot_id in keep_ids or (short_id and short_id in keep_ids):
                continue
            delete_ids.append(snapshot_id)

        if not delete_ids:
            return 0

        log(f"{service_name}: pruning {len(delete_ids)} old snapshot(s) from {repo_path}")
        proc = self.run_as_backup_user(
            ["restic", "-r", repo_path, "forget", "--prune"] + delete_ids,
            check=False,
        )
        if proc.returncode != 0:
            detail = summarize_error(proc.stderr or proc.stdout or "restic forget failed")
            raise RuntimeError(f"failed to prune old snapshots from {repo_path}: {detail}")

        return len(delete_ids)

    def prune_service_local_repos(self, service_name: str, retain_days: int) -> int:
        manifest_dir = self.cluster_data_dir / service_name
        if not manifest_dir.exists():
            return 0

        active_ids = set()
        active_snapshot = self.read_active_snapshot(service_name)
        if active_snapshot is not None:
            snapshot_id = active_snapshot.get("snapshotId")
            if snapshot_id:
                active_ids.add(snapshot_id)

        total_deleted = 0
        self._prune_local_manifests(str(manifest_dir), retain_days, service_name)
        keep_ids = self.repo_manifest_snapshot_ids(manifest_dir) | active_ids

        repo_path = manifest_dir / "repo"
        if repo_path.exists():
            total_deleted += self.prune_local_repo_snapshots(service_name, str(repo_path), keep_ids)

        return total_deleted

    def path_free_bytes(self, path: str) -> int:
        stat = os.statvfs(path)
        return stat.f_bavail * stat.f_frsize

    def backup_service(self, service_name, generation, *, origin="automatic", requested_by=None):
        service = self.services[service_name]
        backup_started_at = time.monotonic()
        retain_days = self.cluster.get("backup", {}).get("retainDays", 7)
        prep_base_percent = 1.0
        prep_end_percent = 20.0
        work_end_percent = 95.0
        cleanup_percent = 96.0

        local_target = service.get("localTarget")
        all_targets: list[dict] = []
        if local_target:
            all_targets.append({"_local": True, **local_target})
        all_targets.extend(service.get("remoteTargets", []))
        target_count = len(all_targets)
        work_start_percent = prep_end_percent if service.get("preBackupCommand") else prep_base_percent

        self.ensure_backup_generation_current(generation, service_name)
        self.start_service_operation(
            service_name,
            action="backup",
            origin=origin,
            phase="preparing backup payload",
            percent=prep_base_percent,
            requested_by=requested_by,
        )
        log(f"starting backup for {service_name} to {target_count} target{'s' if target_count != 1 else ''}")
        successful_targets: list[str] = []
        failed_targets: list[dict] = []
        target_span = (work_end_percent - work_start_percent) / max(1, target_count)
        cleanup_error = None

        try:
            if service.get("preBackupCommand"):
                prep_started_at = time.monotonic()
                self.run_stream(
                    service["preBackupCommand"],
                    on_line=self.prep_progress_updater(
                        service_name,
                        phase="preparing backup payload",
                        base_percent=prep_base_percent,
                        percent_span=prep_end_percent - prep_base_percent,
                    ),
                )
                self.ensure_backup_generation_current(generation, service_name)
                self.update_service_operation(
                    service_name,
                    phase="prepared backup payload",
                    percent=work_start_percent,
                )
                log(f"{service_name}: prepared backup payload in {format_duration(time.monotonic() - prep_started_at)}")

            for target_index, target in enumerate(all_targets):
                self.ensure_backup_generation_current(generation, service_name)
                target_started_at = time.monotonic()
                is_local = target.get("_local", False)
                host_label = "local" if is_local else target["host"]
                repo_path = target["repoPath"]
                manifest_dir = target["manifestDir"]
                base_percent = work_start_percent + target_index * target_span

                try:
                    if is_local:
                        phase = "backing up locally"
                        self.update_service_operation(
                            service_name,
                            phase=phase,
                            percent=base_percent,
                            currentTarget="local",
                            currentTargetIndex=target_index + 1,
                            totalTargets=target_count,
                        )
                        self.run(["install", "-d", "-m", "755", "-o", self.repo_user, repo_path, manifest_dir])
                        self.ensure_restic_repo(repo_path)
                        self.ensure_backup_generation_current(generation, service_name)
                        self.run_as_backup_user_stream(
                            ["restic", "--json", "-r", repo_path, "backup"] + service["backupPaths"],
                            on_line=self.restic_progress_updater(
                                service_name,
                                phase=phase,
                                base_percent=base_percent,
                                percent_span=target_span,
                                extra={
                                    "currentTarget": "local",
                                    "currentTargetIndex": target_index + 1,
                                    "totalTargets": target_count,
                                },
                            ),
                        )
                        self.ensure_backup_generation_current(generation, service_name)
                        snapshot_id = self.latest_snapshot_id(repo_path)
                        if snapshot_id is None:
                            raise RuntimeError(f"no snapshot found after local backup for {service_name}")
                        snap_size = self.restic_snapshot_size(repo_path, snapshot_id)
                        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
                        manifest_path = os.path.join(manifest_dir, f"manifest-{timestamp}.json")
                        manifest = {
                            "service": service_name,
                            "sourceHost": self.hostname,
                            "leaderRevision": self.leader_revision,
                            "completedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                            "snapshotId": snapshot_id,
                            "repoPath": repo_path,
                            "repoUri": repo_path,
                            "snapshotSizeBytes": snap_size,
                        }
                        atomic_write_json(
                            Path(manifest_path),
                            manifest,
                            owner_uid=self.repo_uid,
                            owner_gid=self.repo_gid,
                            mode=0o644,
                        )
                        self._prune_local_manifests(manifest_dir, retain_days, service_name)
                    else:
                        phase = f"replicating to {target['host']}"
                        remote_uri = f"sftp:{self.repo_user}@{target['address']}:{repo_path}"
                        remote_dir = os.path.dirname(repo_path)
                        self.update_service_operation(
                            service_name,
                            phase=phase,
                            percent=base_percent,
                            currentTarget=target["host"],
                            currentTargetIndex=target_index + 1,
                            totalTargets=target_count,
                        )
                        self.run_as_backup_user(
                            ["ssh", target["address"], f"mkdir -p {shlex.quote(remote_dir)} {shlex.quote(manifest_dir)}"]
                        )
                        self.ensure_restic_repo(remote_uri)
                        self.ensure_backup_generation_current(generation, service_name)
                        self.run_as_backup_user_stream(
                            ["restic", "--json", "-r", remote_uri, "backup"] + service["backupPaths"],
                            on_line=self.restic_progress_updater(
                                service_name,
                                phase=phase,
                                base_percent=base_percent,
                                percent_span=target_span,
                                extra={
                                    "currentTarget": target["host"],
                                    "currentTargetIndex": target_index + 1,
                                    "totalTargets": target_count,
                                },
                            ),
                        )
                        self.ensure_backup_generation_current(generation, service_name)
                        snapshot_id = self.latest_snapshot_id(remote_uri)
                        if snapshot_id is None:
                            raise RuntimeError(f"no snapshot found after backing up {service_name} to {target['host']}")
                        snap_size = self.restic_snapshot_size(remote_uri, snapshot_id)
                        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
                        manifest_path = os.path.join(manifest_dir, f"manifest-{timestamp}.json")
                        manifest = {
                            "service": service_name,
                            "sourceHost": self.hostname,
                            "leaderRevision": self.leader_revision,
                            "completedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                            "snapshotId": snapshot_id,
                            "repoPath": repo_path,
                            "repoUri": remote_uri,
                            "snapshotSizeBytes": snap_size,
                        }
                        self.ensure_backup_generation_current(generation, service_name)
                        self.run_as_backup_user(
                            [
                                "ssh",
                                target["address"],
                                (
                                    f"install -m 644 /dev/null {shlex.quote(manifest_path)} "
                                    f"&& cat > {shlex.quote(manifest_path)}"
                                ),
                            ],
                            input_text=json.dumps(manifest, indent=2) + "\n",
                        )
                        prune_cmd = (
                            f"find {shlex.quote(manifest_dir)} -name 'manifest-*.json' "
                            f"-mtime +{retain_days} -delete 2>/dev/null || true"
                        )
                        self.run_as_backup_user(["ssh", target["address"], prune_cmd], check=False)

                    self.update_service_operation(
                        service_name,
                        phase=f"backed up locally" if is_local else f"replicated to {target['host']}",
                        percent=base_percent + target_span,
                        currentTarget=host_label,
                        currentTargetIndex=target_index + 1,
                        totalTargets=target_count,
                    )
                    successful_targets.append(host_label)
                    log(
                        f"{service_name}: {'local backup' if is_local else f'replicated backup to {host_label}'} "
                        f"completed in {format_duration(time.monotonic() - target_started_at)}"
                    )
                    if (
                        is_local
                        and self.min_backup_free_space_bytes > 0
                        and target_index + 1 < target_count
                        and service.get("backupPaths")
                    ):
                        free_bytes = self.path_free_bytes(service["backupPaths"][0])
                        if free_bytes < self.min_backup_free_space_bytes:
                            stop_reason = (
                                "skipping remote replication because only "
                                f"{format_bytes(free_bytes)} free remains after the local backup; "
                                f"need at least {format_bytes(self.min_backup_free_space_bytes)}"
                            )
                            for remaining_target in all_targets[target_index + 1 :]:
                                if remaining_target.get("_local", False):
                                    continue
                                failed_targets.append(
                                    {
                                        "host": remaining_target["host"],
                                        "error": stop_reason,
                                    }
                                )
                            log(f"{service_name}: {stop_reason}")
                            break
                except Exception as exc:
                    failed_targets.append({"host": host_label, "error": summarize_error(str(exc))})
                    self.update_service_operation(
                        service_name,
                        phase=f"failed local backup" if is_local else f"failed replication to {host_label}",
                        percent=base_percent,
                        currentTarget=host_label,
                        currentTargetIndex=target_index + 1,
                        totalTargets=target_count,
                        error=summarize_error(str(exc)),
                    )
                    log(
                        f"{service_name}: {'local backup' if is_local else f'replication to {host_label}'} failed after "
                        f"{format_duration(time.monotonic() - target_started_at)}: {summarize_error(str(exc))}"
                    )
        except Exception as exc:
            log(f"{service_name}: backup failed: {summarize_error(str(exc))}")
            if service.get("postBackupCommand"):
                try:
                    self.update_service_operation(
                        service_name,
                        phase="cleaning up staged backup payload",
                        percent=cleanup_percent,
                    )
                    self.run(service["postBackupCommand"])
                except Exception as cleanup_exc:
                    cleanup_error = summarize_error(str(cleanup_exc))
                    log(f"{service_name}: backup cleanup failed: {cleanup_error}")
            self.clear_service_operation(
                service_name,
                status="failed",
                message=summarize_error(str(exc)),
                details=({"cleanupError": cleanup_error} if cleanup_error else None),
            )
            raise
        else:
            if service.get("postBackupCommand"):
                try:
                    self.update_service_operation(
                        service_name,
                        phase="cleaning up staged backup payload",
                        percent=cleanup_percent,
                    )
                    cleanup_started_at = time.monotonic()
                    self.run(service["postBackupCommand"])
                    log(
                        f"{service_name}: cleaned up staged backup payload in "
                        f"{format_duration(time.monotonic() - cleanup_started_at)}"
                    )
                except Exception as exc:
                    cleanup_error = summarize_error(str(exc))
                    failed_targets.append({"host": "cleanup", "error": cleanup_error})
                    log(f"{service_name}: backup cleanup failed: {cleanup_error}")

            result = {
                "successfulTargets": successful_targets,
                "failedTargets": failed_targets,
                "totalTargets": target_count,
                "durationSeconds": time.monotonic() - backup_started_at,
            }
            if cleanup_error:
                result["cleanupError"] = cleanup_error
            try:
                pruned_snapshot_count = self.prune_service_local_repos(service_name, retain_days)
            except Exception as exc:
                maintenance_error = summarize_error(str(exc))
                result["maintenanceError"] = maintenance_error
                log(f"{service_name}: local backup maintenance failed: {maintenance_error}")
            else:
                if pruned_snapshot_count > 0:
                    result["prunedSnapshotCount"] = pruned_snapshot_count
            if failed_targets:
                if successful_targets:
                    message = f"backed up to {len(successful_targets)}/{target_count} targets"
                    self.clear_service_operation(service_name, status="degraded", message=message, details=result)
                else:
                    self.clear_service_operation(service_name, status="failed", message="backup failed on all targets", details=result)
            else:
                self.clear_service_operation(
                    service_name,
                    status="completed",
                    message=f"backup completed in {format_duration(result['durationSeconds'])}",
                    details=result,
                )
            return result

    def restore_service(self, service_name, manifest, *, progress_callback=None):
        service = self.services[service_name]
        repo_path = manifest["repoPath"]
        snapshot_id = manifest["snapshotId"]
        restore_started_at = time.monotonic()
        source_host = manifest.get("sourceHost", "unknown")
        completed_at = manifest.get("completedAt", "unknown")
        log(
            f"starting restore for {service_name} from {source_host} "
            f"(snapshot {snapshot_id}, completed {completed_at})"
        )
        restore_target = service.get("restoreTarget")
        restore_root = restore_target or tempfile.mkdtemp(prefix=f"alanix-cluster-{service_name}-", dir="/var/tmp")
        try:
            if restore_target:
                for backup_path in service["backupPaths"]:
                    remove_path(backup_path)
                    os.makedirs(os.path.dirname(backup_path), exist_ok=True)
            restic_started_at = time.monotonic()
            self.run_stream(
                ["restic", "--json", "-r", repo_path, "restore", snapshot_id, "--target", restore_root],
                env={"RESTIC_PASSWORD_FILE": self.password_file},
                on_line=progress_callback,
            )
            log(f"{service_name}: restic restore complete in {format_duration(time.monotonic() - restic_started_at)}")
            if not restore_target:
                for backup_path in service["backupPaths"]:
                    source_path = os.path.join(restore_root, backup_path.lstrip("/"))
                    if not os.path.exists(source_path):
                        raise RuntimeError(f"restore path missing for {service_name}: {source_path}")
                    remove_path(backup_path)
                    os.makedirs(os.path.dirname(backup_path), exist_ok=True)
                    copy_started_at = time.monotonic()
                    if os.path.isdir(source_path):
                        shutil.copytree(source_path, backup_path, symlinks=True)
                    else:
                        shutil.copy2(source_path, backup_path)
                    log(f"{service_name}: copied {backup_path} in {format_duration(time.monotonic() - copy_started_at)}")
            if service.get("postRestoreCommand"):
                post_started_at = time.monotonic()
                log(f"{service_name}: running post-restore command")
                self.run(service["postRestoreCommand"])
                log(f"{service_name}: post-restore command complete in {format_duration(time.monotonic() - post_started_at)}")
            self.write_active_snapshot(service_name, manifest)
            log(
                f"completed restore for {service_name} from {source_host} in "
                f"{format_duration(time.monotonic() - restore_started_at)}"
            )
        except Exception as exc:
            log(f"restore failed for {service_name} from {source_host} after "
                f"{format_duration(time.monotonic() - restore_started_at)}: {summarize_error(str(exc))}")
            raise
        finally:
            if not restore_target:
                shutil.rmtree(restore_root, ignore_errors=True)

    def verify_manifest(self, service_name, manifest, *, requested_by=None):
        repo_path = manifest["repoPath"]
        snapshot_id = manifest["snapshotId"]
        log(f"{service_name}: verifying snapshot {snapshot_id} in {repo_path}")
        self.start_service_operation(
            service_name,
            action="verify",
            origin="manual",
            phase="checking snapshot metadata",
            percent=5.0,
            requested_by=requested_by,
        )
        snapshot = self.validate_snapshot_exists(repo_path, snapshot_id)
        self.update_service_operation(
            service_name,
            phase="reading a subset of repository data",
            percent=30.0,
            snapshot=snapshot.get("short_id") or snapshot_id,
        )
        self.run_stream(
            ["restic", "--json", "-r", repo_path, "check", "--read-data-subset=5%"],
            env={"RESTIC_PASSWORD_FILE": self.password_file},
            on_line=self.restic_progress_updater(
                service_name,
                phase="reading a subset of repository data",
                base_percent=30.0,
                percent_span=65.0,
            ),
        )
        details = {
            "repoPath": repo_path,
            "snapshotId": snapshot.get("short_id") or snapshot_id,
        }
        self.clear_service_operation(
            service_name,
            status="completed",
            message=f"verified snapshot {details['snapshotId']}",
            details=details,
        )
        log(f"{service_name}: verified snapshot {details['snapshotId']}")
        return details

    def restore_manifest(self, service_name, manifest, *, requested_by=None):
        was_active = self.any_managed_unit_active()
        self.start_service_operation(
            service_name,
            action="restore",
            origin="manual",
            phase="stopping workloads",
            percent=2.0,
            requested_by=requested_by,
        )
        if was_active:
            self.stop_target()
        try:
            self.update_service_operation(
                service_name,
                phase="restoring snapshot contents",
                percent=15.0,
                restoringSnapshot=manifest.get("snapshotId"),
            )
            self.restore_service(
                service_name,
                manifest,
                progress_callback=self.restic_progress_updater(
                    service_name,
                    phase="restoring snapshot contents",
                    base_percent=15.0,
                    percent_span=70.0,
                ),
            )
        except Exception as exc:
            log(f"{service_name}: manual restore failed: {summarize_error(str(exc))}")
            if was_active and self.lease_id is not None:
                try:
                    self.start_target()
                except Exception as start_exc:
                    log(f"{service_name}: failed to restart workloads after restore failure: {summarize_error(str(start_exc))}")
            raise

        self.update_service_operation(
            service_name,
            phase="starting workloads",
            percent=92.0,
        )
        if was_active and self.lease_id is not None:
            self.start_target()
        self.clear_service_operation(
            service_name,
            status="completed",
            message=f"restored snapshot {manifest.get('snapshotId')}",
            details={
                "manifestPath": manifest.get("_path"),
                "snapshotId": manifest.get("snapshotId"),
                "repoPath": manifest.get("repoPath"),
            },
        )

    def pin_manifest(self, service_name, manifest, *, requested_by=None, note=None):
        log(f"{service_name}: pinning snapshot {manifest.get('snapshotId')}" + (f" ({note})" if note else ""))
        pin_path = self.pin_record_path(service_name, manifest["_path"])
        record = {
            "service": service_name,
            "manifestPath": manifest["_path"],
            "snapshotId": manifest.get("snapshotId"),
            "repoPath": manifest.get("repoPath"),
            "pinnedAt": iso_timestamp(),
            "requestedBy": requested_by,
            "note": note or "",
        }
        atomic_write_json(pin_path, record)
        self.record_operation_history(
            {
                "service": service_name,
                "action": "pin",
                "status": "completed",
                "message": f"pinned snapshot {manifest.get('snapshotId')}",
                "requestedBy": requested_by,
                "details": record,
            }
        )
        return record

    def unpin_manifest(self, service_name, manifest, *, requested_by=None):
        log(f"{service_name}: unpinning snapshot {manifest.get('snapshotId')}")
        pin_path = self.pin_record_path(service_name, manifest["_path"])
        pin_path.unlink(missing_ok=True)
        record = {
            "service": service_name,
            "manifestPath": manifest["_path"],
            "snapshotId": manifest.get("snapshotId"),
            "repoPath": manifest.get("repoPath"),
        }
        self.record_operation_history(
            {
                "service": service_name,
                "action": "unpin",
                "status": "completed",
                "message": f"unpinned snapshot {manifest.get('snapshotId')}",
                "requestedBy": requested_by,
                "details": record,
            }
        )
        return record

    def delete_manifest(self, service_name: str, manifest: dict, *, requested_by: str | None = None) -> dict:
        manifest_path = manifest["_path"]
        snapshot_id = manifest.get("snapshotId")
        repo_path = manifest.get("repoPath")

        if self.read_pin_record(service_name, manifest_path) is not None:
            raise RuntimeError("cannot delete a pinned manifest; unpin it first")

        if not snapshot_id:
            raise RuntimeError("manifest is missing snapshotId; cannot delete backup safely")
        if not repo_path:
            raise RuntimeError("manifest is missing repoPath; cannot delete backup safely")

        log(f"{service_name}: forgetting snapshot {snapshot_id} from {repo_path}")
        proc = self.run_as_backup_user(
            ["restic", "-r", repo_path, "forget", "--prune", snapshot_id],
            check=False,
        )
        if proc.returncode != 0:
            detail = summarize_error(proc.stderr or proc.stdout or "restic forget failed")
            log(f"{service_name}: failed to delete snapshot {snapshot_id}: {detail}")
            raise RuntimeError(f"failed to delete snapshot {snapshot_id}: {detail}")

        Path(manifest_path).unlink(missing_ok=True)
        log(f"{service_name}: deleted manifest {manifest_path}")

        result = {
            "service": service_name,
            "manifestPath": manifest_path,
            "snapshotId": snapshot_id,
            "repoPath": repo_path,
        }
        self.record_operation_history({
            "service": service_name,
            "action": "delete-manifest",
            "status": "completed",
            "message": f"deleted snapshot {snapshot_id}",
            "requestedBy": requested_by,
            "details": result,
        })
        return result

    def new_runtime_mode_payload(self, mode, *, requested_by=None, standalone_host=None):
        return {
            "mode": mode,
            "generation": str(int(time.time() * 1000)),
            "standaloneHost": standalone_host or self.hostname,
            "requestedBy": requested_by,
            "requestedAt": iso_timestamp(),
            "updatedAt": iso_timestamp(),
        }

    def require_no_backups_running(self):
        if self.running_backups:
            running = ", ".join(sorted(self.running_backups))
            raise RuntimeError(f"cannot change runtime mode while backup(s) are running: {running}")

    def enter_planned_standalone(self, *, requested_by=None):
        self.require_no_backups_running()
        if self.lease_id is None:
            raise RuntimeError("planned standalone may only be entered from the current leader")
        payload = self.new_runtime_mode_payload("planned-standalone", requested_by=requested_by)
        log(f"entering planned standalone on {self.hostname}")
        self.write_local_runtime_mode(payload)
        mode_state = self.put_etcd_runtime_mode(payload)
        self.ack_runtime_mode(mode_state)
        self.wait_for_runtime_mode_acks(mode_state, required_hosts=self.voters)
        self.release_leadership_keep_workloads("planned standalone acknowledged by all voters")
        self.record_operation_history(
            {
                "action": "enter-planned-standalone",
                "status": "completed",
                "requestedBy": requested_by,
                "message": f"planned standalone active on {self.hostname}",
                "details": mode_state,
            }
        )
        return mode_state

    def enter_emergency_standalone(self, request, *, requested_by=None):
        self.require_no_backups_running()
        if request.get("confirmation") != "peers-fenced":
            raise RuntimeError("emergency standalone requires confirmation that the other voters are powered off or isolated")
        payload = self.new_runtime_mode_payload("emergency-standalone", requested_by=requested_by)
        payload["fencingConfirmation"] = "human-confirmed"
        payload["reason"] = "local emergency override"
        log(f"entering emergency standalone on {self.hostname}")
        mode_state = self.write_local_runtime_mode(payload)
        self.release_leadership_keep_workloads("emergency standalone local override")
        if not self.target_is_active():
            self.start_target()
        self.record_operation_history(
            {
                "action": "enter-emergency-standalone",
                "status": "completed",
                "requestedBy": requested_by,
                "message": f"emergency standalone active on {self.hostname}",
                "details": mode_state,
            }
        )
        return mode_state

    def seed_resume_backups(self, *, requested_by=None):
        generation = self.advance_backup_generation()
        self.resume_seed_generation = generation
        try:
            results = {}
            for service_name, service in self.services.items():
                if service.get("recoveryMode") == "declarative":
                    continue
                result = self.backup_service(
                    service_name,
                    generation,
                    origin="resume-seeding",
                    requested_by=requested_by,
                )
                results[service_name] = result
                failed_targets = result.get("failedTargets") or []
                if failed_targets:
                    summary = "; ".join(f"{item['host']}: {item['error']}" for item in failed_targets)
                    raise RuntimeError(f"{service_name}: resume backup did not reach every target: {summary}")
            return results
        finally:
            self.resume_seed_generation = None

    def resume_ha(self, *, requested_by=None):
        self.require_no_backups_running()
        mode_state = self.effective_runtime_mode()
        mode = mode_state.get("mode")
        if mode == self.HA_MODE:
            raise RuntimeError("cluster is already in normal HA mode")
        standalone_host = mode_state.get("standaloneHost")
        if standalone_host != self.hostname:
            raise RuntimeError(f"resume HA must be started from standalone host {standalone_host}")

        pending_payload = self.new_runtime_mode_payload(
            "resume-pending",
            requested_by=requested_by,
            standalone_host=self.hostname,
        )
        self.write_local_runtime_mode(pending_payload)

        seeding_payload = dict(pending_payload)
        seeding_payload["mode"] = "resume-seeding"
        seeding_payload["updatedAt"] = iso_timestamp()
        log(f"starting HA resume seeding from {self.hostname}")
        seeding_state = self.put_etcd_runtime_mode(seeding_payload)
        self.ack_runtime_mode(seeding_state)
        self.wait_for_runtime_mode_acks(seeding_state, required_hosts=self.voters)
        results = self.seed_resume_backups(requested_by=requested_by)

        ha_payload = self.new_runtime_mode_payload(
            self.HA_MODE,
            requested_by=requested_by,
            standalone_host=self.hostname,
        )
        ha_state = self.put_etcd_runtime_mode(ha_payload)
        self.clear_local_runtime_mode()
        self.ack_runtime_mode(ha_state)
        self.wait_for_runtime_mode_acks(ha_state, required_hosts=self.voters)
        self.delete_etcd_runtime_mode()
        self.record_operation_history(
            {
                "action": "resume-ha",
                "status": "completed",
                "requestedBy": requested_by,
                "message": "normal HA resumed after fresh backup seeding",
                "details": {"services": results},
            }
        )
        return {"mode": self.HA_MODE, "seededServices": sorted(results)}

    def execute_admin_request(self, request):
        action = request["action"]
        service_name = request.get("service")
        requested_by = request.get("requestedBy")

        if action == "enter-planned-standalone":
            return self.enter_planned_standalone(requested_by=requested_by)

        if action == "enter-emergency-standalone":
            return self.enter_emergency_standalone(request, requested_by=requested_by)

        if action == "resume-ha":
            return self.resume_ha(requested_by=requested_by)

        if action == "backup-now":
            return self.backup_service(service_name, self.backup_generation, origin="manual", requested_by=requested_by)

        if action == "verify-manifest":
            manifest = self.find_manifest(service_name, request["manifestPath"])
            return self.verify_manifest(service_name, manifest, requested_by=requested_by)

        if action == "restore-manifest":
            manifest = self.find_manifest(service_name, request["manifestPath"])
            return self.restore_manifest(service_name, manifest, requested_by=requested_by)

        if action == "pin-manifest":
            manifest = self.find_manifest(service_name, request["manifestPath"])
            return self.pin_manifest(service_name, manifest, requested_by=requested_by, note=request.get("note"))

        if action == "unpin-manifest":
            manifest = self.find_manifest(service_name, request["manifestPath"])
            return self.unpin_manifest(service_name, manifest, requested_by=requested_by)

        if action == "delete-manifest":
            manifest = self.find_manifest(service_name, request["manifestPath"])
            return self.delete_manifest(service_name, manifest, requested_by=requested_by)

        raise RuntimeError(f"unsupported admin action: {action}")

    def recover_services(self, *, allow_stale=False):
        bootstrap = self.hostname == self.bootstrap_host
        for service_name, service in self.services.items():
            if service.get("recoveryMode") == "declarative":
                description = service.get("recoveryDescription") or "declarative configuration"
                log(f"{service_name}: using {description}; no restore required")
                continue
            manifest = self.freshest_manifest(service_name)
            if manifest is None:
                if bootstrap:
                    log(f"{service_name}: no local backup found, allowing bootstrap on preferred host")
                    continue
                raise RuntimeError(f"{service_name}: no local backup available")
            if not self.manifest_is_fresh(service_name, manifest):
                if bootstrap:
                    log(
                        f"{service_name}: freshest backup is older than maxBackupAge, "
                        "allowing stale bootstrap on preferred host"
                    )
                elif allow_stale:
                    log(
                        f"{service_name}: freshest backup is older than maxBackupAge, "
                        "allowing stale recovery based on local backup recency"
                    )
                else:
                    raise RuntimeError(f"{service_name}: freshest backup is older than maxBackupAge")
            active = self.read_active_snapshot(service_name)
            if active is not None and active.get("snapshotId") == manifest.get("snapshotId"):
                log(f"{service_name}: local state matches snapshot {manifest['snapshotId'][:8]}; skipping restore")
                continue
            self.restore_service(service_name, manifest)

    def promote(self, leader, *, allow_stale=False):
        promotion_started_at = time.monotonic()
        self.lease_id = leader["lease_id"]
        self.leader_revision = leader["create_revision"]
        self.advance_backup_generation()
        log(
            f"won lease for revision {self.leader_revision}; starting promotion "
            f"(allow_stale={'yes' if allow_stale else 'no'})"
        )
        # Promotion can take longer than the lease TTL once restores get large.
        # Start renewing immediately after we acquire the lease so it stays valid
        # while we recover local state and start leader-only units.
        self.start_keepalive(self.lease_id)
        if self.running_backups:
            running = list(self.running_backups.keys())
            log(f"waiting for {len(running)} in-flight backup(s) to finish before restoring: {', '.join(running)}")
            concurrent.futures.wait([b["future"] for b in self.running_backups.values()])
        self.recover_services(allow_stale=allow_stale)
        self.start_target()
        for service_name in self.next_backup_at:
            self.next_backup_at[service_name] = 0.0
        log(
            f"became active with leader revision {self.leader_revision} in "
            f"{format_duration(time.monotonic() - promotion_started_at)}"
        )

    def adopt_existing_leader(self, leader):
        adoption_started_at = time.monotonic()
        self.lease_id = leader["lease_id"]
        self.leader_revision = leader["create_revision"]
        self.advance_backup_generation()
        log(f"recovering local active state for existing leader revision {self.leader_revision}")
        self.start_keepalive(self.lease_id)
        if not self.target_is_active():
            self.recover_services(allow_stale=True)
            self.start_target()
        log(
            f"adopted existing leadership at revision {self.leader_revision} in "
            f"{format_duration(time.monotonic() - adoption_started_at)}"
        )

    def schedule_backup(self, service_name, *, origin="automatic", requested_by=None):
        generation = self.backup_generation
        future = self.backup_executor.submit(
            self.backup_service,
            service_name,
            generation,
            origin=origin,
            requested_by=requested_by,
        )
        self.running_backups[service_name] = {
            "future": future,
            "generation": generation,
            "startedAt": time.monotonic(),
            "origin": origin,
            "requestedBy": requested_by,
        }
        self.write_runtime_state()

    def schedule_due_backups(self, now):
        if self.running_admin_operation is not None:
            return
        available_slots = self.max_concurrent_backups - len(self.running_backups)
        if available_slots <= 0:
            return

        for service_name, service in self.services.items():
            if available_slots <= 0:
                return
            if service.get("recoveryMode") == "declarative":
                continue
            if service_name in self.running_backups:
                continue
            if now < self.next_backup_at[service_name]:
                continue

            self.schedule_backup(service_name)
            available_slots -= 1

    def collect_finished_backups(self):
        state_changed = False
        for service_name, running in list(self.running_backups.items()):
            future = running["future"]
            if not future.done():
                continue

            del self.running_backups[service_name]
            state_changed = True
            generation = running["generation"]
            if generation != self.backup_generation:
                try:
                    future.result()
                except Exception as exc:
                    if self.service_operations.get(service_name) is not None:
                        self.clear_service_operation(
                            service_name,
                            status="cancelled",
                            message="backup result discarded after leadership change",
                            details={"error": summarize_error(str(exc))},
                        )
                    log(f"discarded backup result for {service_name} from previous leadership: {summarize_error(str(exc))}")
                else:
                    if self.service_operations.get(service_name) is not None:
                        self.clear_service_operation(
                            service_name,
                            status="cancelled",
                            message="backup result discarded after leadership change",
                        )
                    log(f"discarded completed backup result for {service_name} from previous leadership")
                continue

            service = self.services[service_name]
            next_due = time.monotonic() + parse_duration_seconds(service["backupInterval"])

            try:
                result = future.result()
            except Exception as exc:
                self.next_backup_at[service_name] = next_due
                self.clear_service_operation(
                    service_name,
                    status="failed",
                    message=summarize_error(str(exc)),
                    details={"error": summarize_error(str(exc))},
                )
                log(
                    f"backup for {service_name} failed; keeping leader active while replication is degraded: "
                    f"{summarize_error(str(exc))}"
                )
                continue

            self.next_backup_at[service_name] = next_due
            failed_targets = result["failedTargets"]
            if not failed_targets:
                log(
                    f"completed backup for {service_name} in "
                    f"{format_duration(result['durationSeconds'])}"
                )
                continue

            successful_target_count = len(result["successfulTargets"])
            failure_summary = "; ".join(
                f"{item['host']}: {item['error']}" for item in failed_targets
            )
            if successful_target_count > 0:
                log(
                    f"completed degraded backup for {service_name}: replicated to "
                    f"{successful_target_count}/{result['totalTargets']} targets; "
                    f"failed targets: {failure_summary}; "
                    f"duration {format_duration(result['durationSeconds'])}"
                )
            else:
                log(
                    f"backup for {service_name} failed on all {result['totalTargets']} targets; "
                    f"keeping leader active while replication is degraded: {failure_summary}; "
                    f"duration {format_duration(result['durationSeconds'])}"
                )

        if state_changed:
            self.write_runtime_state()

    def start_admin_request(self, request):
        action = request["action"]
        service_name = request.get("service")
        requested_by = request.get("requestedBy")
        submitted_at = request.get("submittedAt") or iso_timestamp()
        mode_actions = {"enter-planned-standalone", "enter-emergency-standalone", "resume-ha"}
        service_actions = {"backup-now", "verify-manifest", "restore-manifest", "pin-manifest", "unpin-manifest", "delete-manifest"}

        if action in service_actions:
            if not service_name or service_name not in self.services:
                raise RuntimeError(f"unknown service for {action}: {service_name!r}")
            mode_state = self.effective_runtime_mode()
            if mode_state.get("mode") != self.HA_MODE:
                raise RuntimeError(f"{action} is disabled while cluster runtime mode is {mode_state.get('mode')}")

        if action in mode_actions:
            self.require_no_backups_running()

        if action == "backup-now" and self.lease_id is None:
            raise RuntimeError("manual backups may only run on the current leader")

        if action == "backup-now":
            if service_name in self.running_backups:
                raise RuntimeError(f"{service_name} backup is already running")
            if len(self.running_backups) >= self.max_concurrent_backups:
                running = ", ".join(sorted(self.running_backups)) or "unknown"
                raise RuntimeError(
                    f"all backup slots are busy ({len(self.running_backups)}/{self.max_concurrent_backups}); "
                    f"running: {running}"
                )
            self.schedule_backup(service_name, origin="manual", requested_by=requested_by)
            self.complete_admin_request_file(request)
            return

        if action in {"verify-manifest", "restore-manifest"} and self.running_backups:
            running = ", ".join(sorted(self.running_backups)) or "unknown"
            raise RuntimeError(
                f"another backup is already running ({running}); wait for it to finish and try again"
            )

        if action == "delete-manifest" and service_name in self.running_backups:
            raise RuntimeError(f"a backup for {service_name} is in progress; wait for it to finish and try again")

        state = {
            "action": action,
            "service": service_name or "",
            "requestedBy": requested_by,
            "submittedAt": submitted_at,
            "startedAt": iso_timestamp(),
            "status": "running",
        }
        self.running_admin_operation = {
            "request": request,
            "future": self.admin_executor.submit(self.execute_admin_request, request),
            "state": state,
        }
        self.write_runtime_state()

    def fail_admin_request(self, request, message):
        action = request.get("action", "unknown")
        service = request.get("service", "unknown")
        log(f"admin request failed [{action} {service}]: {message}")
        self.complete_admin_request_file(request)
        self.record_operation_history(
            {
                "service": request.get("service"),
                "action": action,
                "status": "failed",
                "requestedBy": request.get("requestedBy"),
                "message": message,
                "details": {"request": request},
            }
        )

    def collect_finished_admin_operations(self):
        if self.running_admin_operation is None:
            return

        future = self.running_admin_operation["future"]
        if not future.done():
            return

        request = self.running_admin_operation["request"]
        action = request["action"]
        service_name = request.get("service")
        requested_by = request.get("requestedBy")
        self.complete_admin_request_file(request)

        try:
            result = future.result()
        except Exception as exc:
            log(f"admin request failed [{action} {service_name}]: {summarize_error(str(exc))}")
            if action in {"pin-manifest", "unpin-manifest"}:
                self.record_operation_history(
                    {
                        "service": service_name,
                        "action": action,
                        "status": "failed",
                        "requestedBy": requested_by,
                        "message": summarize_error(str(exc)),
                    }
                )
            elif service_name and self.service_operations.get(service_name) is not None:
                self.clear_service_operation(
                    service_name,
                    status="failed",
                    message=summarize_error(str(exc)),
                    details={"error": summarize_error(str(exc))},
                )
            else:
                self.record_operation_history(
                    {
                        "service": service_name,
                        "action": action,
                        "status": "failed",
                        "requestedBy": requested_by,
                        "message": summarize_error(str(exc)),
                    }
                )
        else:
            if action == "backup-now" and service_name is not None:
                next_due = time.monotonic() + parse_duration_seconds(self.services[service_name]["backupInterval"])
                self.next_backup_at[service_name] = next_due

        self.running_admin_operation = None
        self.write_runtime_state()

    def process_admin_requests(self):
        self.collect_finished_admin_operations()
        if self.running_admin_operation is not None:
            return

        request = self.take_next_admin_request()
        if request is None:
            return

        try:
            self.start_admin_request(request)
        except Exception as exc:
            self.fail_admin_request(request, summarize_error(str(exc)))

    def tick_active(self):
        if self.keepalive_proc is None or self.keepalive_proc.poll() is not None:
            output = self.recent_keepalive_output()
            self.demote(f"lease keepalive exited: {output}")
            return

        try:
            leader = self.get_leader()
        except EtcdUnavailable as exc:
            ack_age = self.keepalive_ack_age()
            keepalive_fresh_for = max(5.0, self.lease_ttl * 0.75)
            if ack_age is not None and ack_age <= keepalive_fresh_for:
                self.log_every(
                    "last_active_etcd_warning_at",
                    30.0,
                    f"leader check failed but keepalive was acknowledged {format_duration(ack_age)} ago; "
                    f"staying active and pausing new backup scheduling: {summarize_error(str(exc))}",
                )
                return
            ack_summary = "never" if ack_age is None else f"{format_duration(ack_age)} ago"
            output = self.recent_keepalive_output()
            self.demote(
                "leader check failed and keepalive is not recently acknowledged "
                f"(last ack {ack_summary}): {summarize_error(str(exc))}; keepalive output: {output}"
            )
            return
        if leader is None:
            self.demote("leader key disappeared")
            return
        if leader["host"] != self.hostname or leader["lease_id"] != self.lease_id:
            self.demote(f"leadership moved to {leader['host']}")
            return

        ack_age = self.keepalive_ack_age()
        keepalive_restart_after = max(5.0, self.lease_ttl / 2.0)
        if ack_age is not None and ack_age > keepalive_restart_after:
            log(
                f"lease keepalive has not been acknowledged for {format_duration(ack_age)}; "
                f"restarting keepalive via {self.current_etcd_endpoint()}"
            )
            self.start_keepalive(self.lease_id)

        now = time.monotonic()
        self.schedule_due_backups(now)

    def tick_passive(self):
        try:
            leader = self.get_leader()
        except EtcdUnavailable as exc:
            self.last_leader_absent_at = None
            self.log_every(
                "last_passive_etcd_warning_at",
                30.0,
                f"cannot check cluster leader because etcd is unavailable; staying passive: {summarize_error(str(exc))}",
            )
            if self.any_managed_unit_active():
                log("stopping active target because this node is passive and etcd leader state is unavailable")
                self.stop_target()
            return
        if leader is not None:
            self.last_leader_absent_at = None
            if leader["host"] == self.hostname:
                self.adopt_existing_leader(leader)
            elif self.any_managed_unit_active():
                log(f"stopping active target because {leader['host']} holds the cluster lease")
                self.stop_target()
            return

        if self.any_managed_unit_active():
            log("stopping active target because no cluster lease is present")
            self.stop_target()

        peer_mode, _ = self.peer_guard_mode()
        if peer_mode.get("mode") != self.HA_MODE:
            if peer_mode.get("mode") == "peer-unknown":
                self.log_every(
                    "last_peer_guard_warning_at",
                    30.0,
                    "not acquiring leadership because peer dashboard mode could not be confirmed",
                )
                return
            log(f"not acquiring leadership because peer reports runtime mode {peer_mode.get('mode')}")
            self.write_local_runtime_mode(peer_mode)
            return

        now = time.monotonic()
        if self.last_leader_absent_at is None:
            self.last_leader_absent_at = now
            return

        recovery_profile = self.local_recovery_profile()
        if recovery_profile["allFresh"]:
            wait_seconds = self.priority_index * self.acquisition_step
            allow_stale = False
        else:
            wait_seconds = self.stale_recovery_wait_seconds(recovery_profile["worstAgeSeconds"])
            allow_stale = True

        if now - self.last_leader_absent_at < wait_seconds:
            return

        leader = self.acquire_lease()
        if leader is None:
            return

        try:
            self.promote(leader, allow_stale=allow_stale)
        except Exception as exc:
            self.demote(f"promotion failed: {exc}")

    def run_forever(self):
        while True:
            try:
                self.collect_finished_backups()
                self.process_admin_requests()
                mode_state = self.effective_runtime_mode()
                if self.apply_runtime_mode(mode_state):
                    pass
                elif self.lease_id is None:
                    self.tick_passive()
                else:
                    self.tick_active()
            except Exception as exc:
                if self.lease_id is not None:
                    self.demote(f"unexpected error while active: {exc}")
                else:
                    log(f"passive error: {exc}")
            self.write_runtime_state()
            time.sleep(1)


def main():
    if len(sys.argv) != 2:
        print("usage: controller.py <config.json>", file=sys.stderr)
        raise SystemExit(2)
    controller = Controller(sys.argv[1])
    controller.run_forever()


if __name__ == "__main__":
    main()
