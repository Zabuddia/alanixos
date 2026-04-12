#!/usr/bin/env python3

import base64
import glob
import json
import math
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
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
        self.endpoints = self.cluster["endpoints"]
        self.bootstrap_host = self.cluster["bootstrapHost"]
        self.priority = self.cluster["priority"]
        self.priority_index = self.priority.index(self.hostname)
        self.lease_ttl = int(parse_duration_seconds(self.cluster["etcd"]["leaseTtl"]))
        self.acquisition_step = parse_duration_seconds(self.cluster["etcd"]["acquisitionStep"])

        self.keepalive_proc = None
        self.lease_id = None
        self.leader_revision = None
        self.last_leader_absent_at = None
        self.next_backup_at = {name: 0.0 for name in self.services}

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

    def etcdctl(self, args, *, check=True, input_text=None):
        cmd = ["etcdctl", f"--endpoints={','.join(self.endpoints)}", "--write-out=json"] + args
        return self.run(cmd, check=check, input_text=input_text)

    def run_as_backup_user(self, args, *, check=True, input_text=None):
        cmd = ["runuser", "-u", self.repo_user, "--"] + args
        env = {
            "RESTIC_PASSWORD_FILE": self.password_file,
        }
        return self.run(cmd, check=check, input_text=input_text, env=env)

    def get_leader(self):
        proc = self.etcdctl(["get", self.leader_key], check=False)
        if proc.returncode != 0:
            return None
        payload = json.loads(proc.stdout or "{}")
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
        lease_id = self.grant_lease()
        txn = (
            f'version("{self.leader_key}") = "0"\n\n'
            f"put {self.leader_key} {self.hostname} --lease={lease_id_arg(lease_id)}\n\n"
            f"get {self.leader_key}\n\n"
        )
        txn_proc = self.etcdctl(["txn", "-i"], check=False, input_text=txn)
        if txn_proc.returncode != 0:
            log(f"failed lease acquisition transaction: {txn_proc.stderr.strip() or txn_proc.stdout.strip()}")
        leader = self.get_leader()
        if leader and leader["host"] == self.hostname and leader["lease_id"] == lease_id:
            return leader
        self.revoke_lease(lease_id)
        return None

    def start_keepalive(self, lease_id):
        self.stop_keepalive()
        cmd = [
            "etcdctl",
            f"--endpoints={','.join(self.endpoints)}",
            "lease",
            "keep-alive",
            lease_id_arg(lease_id),
        ]
        env = os.environ.copy()
        self.keepalive_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

    def stop_keepalive(self):
        if self.keepalive_proc is not None:
            self.keepalive_proc.terminate()
            try:
                self.keepalive_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.keepalive_proc.kill()
            self.keepalive_proc = None

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
        self.stop_keepalive()
        self.stop_target()
        if self.lease_id is not None:
            self.revoke_lease(self.lease_id)
        self.lease_id = None
        self.leader_revision = None
        self.last_leader_absent_at = None

    def local_manifests_for_service(self, service_name):
        service = self.services[service_name]
        manifests = []
        for path in glob.glob(service["localManifestGlob"]):
            manifest_path = Path(path)
            if not manifest_path.exists():
                continue
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
        max_age_seconds = parse_duration_seconds(self.services[service_name]["maxBackupAge"])
        age = self.manifest_age_seconds(manifest)
        return age <= max_age_seconds

    def local_recovery_profile(self):
        manifests = {}
        all_fresh = True
        worst_age_seconds = 0.0
        missing_services = []

        for service_name in self.services:
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

    def backup_service(self, service_name):
        service = self.services[service_name]
        if service.get("preBackupCommand"):
            self.run(service["preBackupCommand"])

        successful_targets = []
        failed_targets = []

        for target in service["remoteTargets"]:
            try:
                repo_path = target["repoPath"]
                remote_uri = f"sftp:{self.repo_user}@{target['address']}:{repo_path}"
                remote_dir = os.path.dirname(repo_path)
                manifest_path = target["manifestPath"]
                manifest_dir = os.path.dirname(manifest_path)

                self.run_as_backup_user(
                    ["ssh", target["address"], f"mkdir -p {shlex.quote(remote_dir)} {shlex.quote(manifest_dir)}"]
                )
                self.ensure_restic_repo(remote_uri)
                self.run_as_backup_user(["restic", "-r", remote_uri, "backup"] + service["backupPaths"])

                snapshot_id = self.latest_snapshot_id(remote_uri)
                if snapshot_id is None:
                    raise RuntimeError(f"no snapshot found after backing up {service_name} to {target['host']}")

                manifest = {
                    "service": service_name,
                    "sourceHost": self.hostname,
                    "leaderRevision": self.leader_revision,
                    "completedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                    "snapshotId": snapshot_id,
                    "repoPath": repo_path,
                }
                self.run_as_backup_user(
                    ["ssh", target["address"], f"cat > {shlex.quote(manifest_path)}"],
                    input_text=json.dumps(manifest, indent=2) + "\n",
                )
                successful_targets.append(target["host"])
            except Exception as exc:
                failed_targets.append(
                    {
                        "host": target["host"],
                        "error": summarize_error(str(exc)),
                    }
                )

        return {
            "successfulTargets": successful_targets,
            "failedTargets": failed_targets,
            "totalTargets": len(service["remoteTargets"]),
        }

    def restore_service(self, service_name, manifest):
        service = self.services[service_name]
        repo_path = manifest["repoPath"]
        snapshot_id = manifest["snapshotId"]
        restore_root = tempfile.mkdtemp(prefix=f"alanix-cluster-{service_name}-", dir="/var/tmp")
        try:
            self.run(
                ["restic", "-r", repo_path, "restore", snapshot_id, "--target", restore_root],
                env={"RESTIC_PASSWORD_FILE": self.password_file},
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
        finally:
            shutil.rmtree(restore_root, ignore_errors=True)

    def recover_services(self, *, allow_stale=False):
        bootstrap = self.hostname == self.bootstrap_host
        for service_name in self.services:
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
        self.lease_id = leader["lease_id"]
        self.leader_revision = leader["create_revision"]
        # Promotion can take longer than the lease TTL once restores get large.
        # Start renewing immediately after we acquire the lease so it stays valid
        # while we recover local state and start leader-only units.
        self.start_keepalive(self.lease_id)
        self.recover_services(allow_stale=allow_stale)
        self.start_target()
        for service_name in self.next_backup_at:
            self.next_backup_at[service_name] = 0.0
        log(f"became active with leader revision {self.leader_revision}")

    def adopt_existing_leader(self, leader):
        self.lease_id = leader["lease_id"]
        self.leader_revision = leader["create_revision"]
        self.start_keepalive(self.lease_id)
        if not self.target_is_active():
            self.recover_services(allow_stale=True)
            self.start_target()
        log(f"adopted existing leadership at revision {self.leader_revision}")

    def tick_active(self):
        if self.keepalive_proc is None or self.keepalive_proc.poll() is not None:
            stderr = ""
            if self.keepalive_proc is not None and self.keepalive_proc.stderr is not None:
                stderr = self.keepalive_proc.stderr.read()
            self.demote(f"lease keepalive exited: {stderr.strip()}")
            return

        leader = self.get_leader()
        if leader is None:
            self.demote("leader key disappeared")
            return
        if leader["host"] != self.hostname or leader["lease_id"] != self.lease_id:
            self.demote(f"leadership moved to {leader['host']}")
            return

        now = time.monotonic()
        for service_name, service in self.services.items():
            if now >= self.next_backup_at[service_name]:
                try:
                    result = self.backup_service(service_name)
                except Exception as exc:
                    self.next_backup_at[service_name] = now + parse_duration_seconds(service["backupInterval"])
                    log(
                        f"backup for {service_name} failed; keeping leader active while replication is degraded: "
                        f"{summarize_error(str(exc))}"
                    )
                    continue
                self.next_backup_at[service_name] = now + parse_duration_seconds(service["backupInterval"])
                failed_targets = result["failedTargets"]
                if not failed_targets:
                    log(f"completed backup for {service_name}")
                    continue

                successful_target_count = len(result["successfulTargets"])
                failure_summary = "; ".join(
                    f"{item['host']}: {item['error']}" for item in failed_targets
                )
                if successful_target_count > 0:
                    log(
                        f"completed degraded backup for {service_name}: replicated to "
                        f"{successful_target_count}/{result['totalTargets']} targets; "
                        f"failed targets: {failure_summary}"
                    )
                else:
                    log(
                        f"backup for {service_name} failed on all {result['totalTargets']} targets; "
                        f"keeping leader active while replication is degraded: {failure_summary}"
                    )

    def tick_passive(self):
        leader = self.get_leader()
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
                if self.lease_id is None:
                    self.tick_passive()
                else:
                    self.tick_active()
            except Exception as exc:
                if self.lease_id is not None:
                    self.demote(f"unexpected error while active: {exc}")
                else:
                    log(f"passive error: {exc}")
            time.sleep(1)


def main():
    if len(sys.argv) != 2:
        print("usage: controller.py <config.json>", file=sys.stderr)
        raise SystemExit(2)
    controller = Controller(sys.argv[1])
    controller.run_forever()


if __name__ == "__main__":
    main()
