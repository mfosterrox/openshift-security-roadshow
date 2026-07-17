#!/usr/bin/env python3
"""Score roadshow module completion markers across lab bastions via SSH."""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PROGRESS_FILE = "/home/lab-user/.acs-roadshow/progress"
DEFAULT_MODULES = [f"{i:02d}" for i in range(0, 10)] + ["10"]
DEFAULT_USER = "lab-user"
DEFAULT_PORT = 22
CONNECT_TIMEOUT = 15
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_RESULTS_LOG = SCRIPT_DIR / "results.log"

# Accept new markers and legacy MODULE=xx COMPLETE lines from older cleanup scripts
MARKER_RE = re.compile(r"^Module\s+(\S+)\s+done\s*$")
LEGACY_RE = re.compile(r"^MODULE=(\S+)\s+COMPLETE\b")


def parse_modules(modules_arg: str | None) -> list[str]:
    if not modules_arg:
        return list(DEFAULT_MODULES)
    modules = [m.strip() for m in modules_arg.split(",") if m.strip()]
    if not modules:
        raise SystemExit("Error: --modules produced an empty list")
    return modules


def load_bastions_from_csv(csv_path: str) -> list[dict]:
    bastions = []
    with open(csv_path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            raise SystemExit(f"Error: CSV has no header row: {csv_path}")
        fields = {name.strip().lower(): name for name in reader.fieldnames if name}
        required = ("host", "password")
        for key in required:
            if key not in fields:
                raise SystemExit(
                    f"Error: CSV must include columns: host,port,user,password "
                    f"(missing '{key}'). Found: {', '.join(reader.fieldnames)}"
                )
        for row_num, row in enumerate(reader, start=2):
            host = (row.get(fields["host"]) or "").strip()
            if not host:
                continue
            port_raw = (row.get(fields.get("port", "port"), "") or str(DEFAULT_PORT)).strip()
            user = (row.get(fields.get("user", "user"), "") or DEFAULT_USER).strip()
            password = (row.get(fields["password"]) or "").strip()
            try:
                port = int(port_raw)
            except ValueError as exc:
                raise SystemExit(f"Error: invalid port on CSV row {row_num}: {port_raw}") from exc
            if not password:
                raise SystemExit(f"Error: empty password on CSV row {row_num} for host {host}")
            bastions.append(
                {
                    "host": host,
                    "port": port,
                    "user": user or DEFAULT_USER,
                    "password": password,
                }
            )
    if not bastions:
        raise SystemExit(f"Error: no bastion rows found in {csv_path}")
    return bastions


def parse_completed_modules(progress_text: str) -> set[str]:
    completed: set[str] = set()
    for line in progress_text.splitlines():
        line = line.strip()
        match = MARKER_RE.match(line)
        if match:
            completed.add(match.group(1))
            continue
        legacy = LEGACY_RE.match(line)
        if legacy:
            completed.add(legacy.group(1))
    return completed


def fetch_progress(
    host: str, port: int, user: str, password: str, progress_path: str = PROGRESS_FILE
) -> tuple[str | None, str | None]:
    """Return (progress_text, error). On success error is None."""
    try:
        import paramiko
    except ImportError:
        return None, "Connection failed: paramiko is not installed (pip install -r requirements.txt)"

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=host,
            port=port,
            username=user,
            password=password,
            timeout=CONNECT_TIMEOUT,
            allow_agent=False,
            look_for_keys=False,
        )
        # Prefer SFTP read; fall back to remote cat
        try:
            with client.open_sftp() as sftp:
                try:
                    with sftp.file(progress_path, "r") as remote:
                        return remote.read().decode("utf-8", errors="replace"), None
                except (FileNotFoundError, IOError, OSError):
                    return "", None
        except Exception:
            stdin, stdout, stderr = client.exec_command(
                f'test -f "{progress_path}" && cat "{progress_path}" || true',
                timeout=CONNECT_TIMEOUT,
            )
            exit_status = stdout.channel.recv_exit_status()
            if exit_status != 0:
                err = stderr.read().decode("utf-8", errors="replace").strip()
                return None, err or f"remote cat failed with status {exit_status}"
            return stdout.read().decode("utf-8", errors="replace"), None
    except Exception as exc:  # noqa: BLE001 - surface any SSH/auth failure per host
        return None, f"Connection failed: {exc}"
    finally:
        client.close()


def score_host(bastion: dict, modules: list[str]) -> list[str]:
    host = bastion["host"]
    port = bastion["port"]
    user = bastion["user"]
    password = bastion["password"]

    lines = [f"=== {user}@{host}:{port} ==="]
    progress_text, error = fetch_progress(host, port, user, password)
    if error:
        lines.append(error)
        for mod in modules:
            lines.append(f"Module {mod} failed")
        return lines

    if progress_text is None:
        lines.append("Progress file unreadable")
        for mod in modules:
            lines.append(f"Module {mod} failed")
        return lines

    if progress_text == "":
        lines.append(f"Progress file not found: {PROGRESS_FILE}")

    completed = parse_completed_modules(progress_text)
    for mod in modules:
        if mod in completed:
            lines.append(f"Module {mod} success")
        else:
            lines.append(f"Module {mod} failed")
    return lines


def write_results(path: Path, blocks: list[list[str]]) -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"\n# gameify run {stamp}\n")
        for block in blocks:
            fh.write("\n".join(block))
            fh.write("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check roadshow module completion markers on lab bastions."
    )
    parser.add_argument(
        "--csv",
        dest="csv_path",
        help="CSV with columns host,port,user,password (port/user optional)",
    )
    parser.add_argument("-H", "--hostname", help="Single bastion host (quick test mode)")
    parser.add_argument("-P", "--password", help="SSH password for single-host mode")
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"SSH port for single-host mode (default {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--user",
        default=DEFAULT_USER,
        help=f"SSH user for single-host mode (default {DEFAULT_USER})",
    )
    parser.add_argument(
        "--modules",
        help="Comma-separated module ids to score (default: ACS 00-10)",
    )
    parser.add_argument(
        "--results",
        default=str(DEFAULT_RESULTS_LOG),
        help=f"Local aggregate log path (default: {DEFAULT_RESULTS_LOG})",
    )
    args = parser.parse_args(argv)

    modules = parse_modules(args.modules)

    if args.csv_path:
        bastions = load_bastions_from_csv(args.csv_path)
    elif args.hostname and args.password:
        bastions = [
            {
                "host": args.hostname,
                "port": args.port,
                "user": args.user,
                "password": args.password,
            }
        ]
    else:
        parser.error("Provide --csv PATH, or both -H/--hostname and -P/--password")

    all_blocks: list[list[str]] = []
    for bastion in bastions:
        block = score_host(bastion, modules)
        all_blocks.append(block)
        print("\n".join(block))
        print()

    results_path = Path(args.results)
    write_results(results_path, all_blocks)
    print(f"Wrote aggregate results to {results_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
