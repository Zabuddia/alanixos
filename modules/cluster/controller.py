#!/usr/bin/env python3

import base64
import collections
import concurrent.futures
import glob
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
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


def atomic_write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink(missing_ok=True)


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


class EtcdUnavailable(RuntimeError):
    pass


class Controller:
    def __init__(self, config_path: str) -> None:
        with open(config_path, "r", encoding="utf-8") as handle:
            self.config = json.load(handle)

        self.cluster = self.config["cluster"]
        self.services = self.config["services"]
        self.hostname = self.cluster["hostname"]
        self.leader_key = self.cluster["leaderKey"]
        self.target = self.cluster["activeTarget"]
        self.repo_user = self.cluster["backup"]["repoUser"]
        self.password_file = self.cluster["backup"]["passwordFile"]
        self.max_concurrent_backups = max(1, int(self.cluster["backup"].get("maxConcurrent", 2)))
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
        self.run(["systemctl", "start", self.target])

    def stop_target(self):
        self.run(["systemctl", "stop"] + self.managed_units(), check=False)

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

    def advance_backup_generation(self):
        with self.backup_generation_lock:
            self.backup_generation += 1
            return self.backup_generation

    def backup_generation_is_current(self, generation):
        with self.backup_generation_lock:
            return generation == self.backup_generation and self.lease_id is not None

    def ensure_backup_generation_current(self, generation, service_name):
        if not self.backup_generation_is_current(generation):
            raise RuntimeError(f"{service_name}: backup cancelled because leadership changed")

    def service_manifest_globs(self, service_name):
        service = self.services[service_name]
        manifest_glob = service.get("localManifestGlob")
        if manifest_glob:
            return [manifest_glob]
        return []

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
        with self.runtime_state_lock:
            payload = {
                "hostname": self.hostname,
                "leaseId": self.lease_id,
                "leaderRevision": self.leader_revision,
                "isLeader": self.lease_id is not None,
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
        for path in sorted(self.admin_inflight_dir.glob("*.json")):
            target = self.admin_queue_dir / path.name
            path.replace(target)

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
                inflight_path.unlink(missing_ok=True)
                self.record_operation_history(
                    {
                        "action": "admin-request",
                        "status": "failed",
                        "message": f"invalid admin request {path.name}: {summarize_error(str(exc))}",
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
                except json.JSONDecodeError:
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

    def _prune_local_manifests(self, manifest_dir: str, retain_days: int) -> None:
        cutoff = time.time() - retain_days * 86400
        for p in Path(manifest_dir).glob("manifest-*.json"):
            try:
                if p.stat().st_mtime < cutoff:
                    p.unlink()
                    log(f"pruned old manifest: {p}")
            except OSError:
                pass

    def backup_service(self, service_name, generation, *, origin="automatic", requested_by=None):
        service = self.services[service_name]
        backup_started_at = time.monotonic()
        retain_days = self.cluster.get("backup", {}).get("retainDays", 7)

        local_target = service.get("localTarget")
        all_targets: list[dict] = []
        if local_target:
            all_targets.append({"_local": True, **local_target})
        all_targets.extend(service.get("remoteTargets", []))
        target_count = len(all_targets)

        self.ensure_backup_generation_current(generation, service_name)
        self.start_service_operation(
            service_name,
            action="backup",
            origin=origin,
            phase="preparing backup payload",
            percent=1.0,
            requested_by=requested_by,
        )
        log(f"starting backup for {service_name} to {target_count} target{'s' if target_count != 1 else ''}")
        if service.get("preBackupCommand"):
            prep_started_at = time.monotonic()
            self.run(service["preBackupCommand"])
            self.ensure_backup_generation_current(generation, service_name)
            self.update_service_operation(
                service_name,
                phase="prepared backup payload",
                percent=5.0,
            )
            log(f"{service_name}: prepared backup payload in {format_duration(time.monotonic() - prep_started_at)}")

        successful_targets: list[str] = []
        failed_targets: list[dict] = []
        target_span = 90.0 / max(1, target_count)

        for target_index, target in enumerate(all_targets):
            self.ensure_backup_generation_current(generation, service_name)
            target_started_at = time.monotonic()
            is_local = target.get("_local", False)
            host_label = "local" if is_local else target["host"]
            repo_path = target["repoPath"]
            manifest_dir = target["manifestDir"]
            base_percent = 5.0 + target_index * target_span

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
                    atomic_write_json(Path(manifest_path), manifest)
                    self._prune_local_manifests(manifest_dir, retain_days)
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
                        ["ssh", target["address"], f"cat > {shlex.quote(manifest_path)}"],
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

        result = {
            "successfulTargets": successful_targets,
            "failedTargets": failed_targets,
            "totalTargets": target_count,
            "durationSeconds": time.monotonic() - backup_started_at,
        }
        if failed_targets:
            message = (
                f"backed up to {len(successful_targets)}/{target_count} targets"
                if successful_targets
                else "backup failed on all targets"
            )
            self.clear_service_operation(service_name, status="degraded", message=message, details=result)
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
        restore_root = tempfile.mkdtemp(prefix=f"alanix-cluster-{service_name}-", dir="/var/tmp")
        try:
            self.run_stream(
                ["restic", "--json", "-r", repo_path, "restore", snapshot_id, "--target", restore_root],
                env={"RESTIC_PASSWORD_FILE": self.password_file},
                on_line=progress_callback,
            )
            for backup_path in service["backupPaths"]:
                source_path = os.path.join(restore_root, backup_path.lstrip("/"))
                if not os.path.exists(source_path):
                    raise RuntimeError(f"restore path missing for {service_name}: {source_path}")
                if os.path.isdir(backup_path):
                    shutil.rmtree(backup_path, ignore_errors=True)
                elif os.path.isfile(backup_path):
                    os.remove(backup_path)
                os.makedirs(os.path.dirname(backup_path), exist_ok=True)
                if os.path.isdir(source_path):
                    shutil.copytree(source_path, backup_path, symlinks=True)
                else:
                    shutil.copy2(source_path, backup_path)
            if service.get("postRestoreCommand"):
                self.run(service["postRestoreCommand"])
            log(
                f"completed restore for {service_name} from {source_host} in "
                f"{format_duration(time.monotonic() - restore_started_at)}"
            )
        finally:
            shutil.rmtree(restore_root, ignore_errors=True)

    def verify_manifest(self, service_name, manifest, *, requested_by=None):
        repo_path = manifest["repoPath"]
        snapshot_id = manifest["snapshotId"]
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
        except Exception:
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

    def execute_admin_request(self, request):
        action = request["action"]
        service_name = request.get("service")
        requested_by = request.get("requestedBy")

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

    def schedule_backup(self, service_name):
        generation = self.backup_generation
        future = self.backup_executor.submit(self.backup_service, service_name, generation)
        self.running_backups[service_name] = {
            "future": future,
            "generation": generation,
            "startedAt": time.monotonic(),
        }

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
        for service_name, running in list(self.running_backups.items()):
            future = running["future"]
            if not future.done():
                continue

            del self.running_backups[service_name]
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

    def start_admin_request(self, request):
        action = request["action"]
        service_name = request.get("service")
        requested_by = request.get("requestedBy")
        submitted_at = request.get("submittedAt") or iso_timestamp()

        if action in {"backup-now", "verify-manifest", "restore-manifest", "pin-manifest", "unpin-manifest", "delete-manifest"}:
            if not service_name or service_name not in self.services:
                raise RuntimeError(f"unknown service for {action}: {service_name!r}")

        if action == "backup-now" and self.lease_id is None:
            raise RuntimeError("manual backups may only run on the current leader")

        if action in {"backup-now", "verify-manifest", "restore-manifest", "delete-manifest"} and self.running_backups:
            raise RuntimeError("another backup is already running; wait for it to finish and try again")

        state = {
            "action": action,
            "service": service_name,
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
        self.complete_admin_request_file(request)
        self.record_operation_history(
            {
                "service": request.get("service"),
                "action": request.get("action"),
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
                if self.lease_id is None:
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
