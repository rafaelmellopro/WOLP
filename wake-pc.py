#!/usr/bin/env python3
"""Wake-on-LAN / shutdown helper for the wolp.pc bar widget.

Usage: wake-pc.py <status|wake|shutdown> [options]

Always prints one JSON line: {"state": "...", "detail": "..."}
state is one of: online, offline, pending, sent, error. A successful ping
also adds "latency" (milliseconds).

--mode picks how the PC is woken and how its status is checked:
  magic-packet  send a Wake-on-LAN packet, ping --host for status
  upsnap        ask an UpSnap server, read the device status from it

--shutdown-method picks how the PC is shut down, independently of --mode:
  none          shutdown disabled
  upsnap        UpSnap's configured shutdown command
  ssh           run --shutdown-command on the PC over SSH (key auth)
  windows       Samba `net rpc shutdown` against a Windows PC
  http          request --shutdown-url (webhook, Home Assistant, ...)
  command       run --shutdown-command locally with sh

The widget passes the options as a JSON object in $WAKE_PC_CONFIG instead
(keys are the option names without "--"), so URLs and commands that carry
tokens never show up in `ps`. Options on the command line take precedence.
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

TIMEOUT = 5
DEFAULT_SSH_COMMAND = "sudo systemctl poweroff"


def emit(state, detail="", **extra):
    print(json.dumps({"state": state, "detail": detail, **extra}))
    sys.exit(0)


def run(cmd, timeout=15, env=None, shell=False):
    """Run a command; return (ok, message) with the last line of its error output."""
    try:
        result = subprocess.run(
            cmd,
            shell=shell,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        name = cmd if isinstance(cmd, str) else cmd[0]
        return False, f"{name} is not installed"
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"
    output = (result.stderr or result.stdout or "").strip().splitlines()
    return result.returncode == 0, (output[-1] if output else f"exit code {result.returncode}")


def read_secret(path):
    if not path:
        return ""
    expanded = os.path.expanduser(path)
    # Refuse loose permissions: without this, any other local account could
    # read the password. The error reaches the panel via main()'s handler.
    if os.stat(expanded).st_mode & 0o077:
        raise PermissionError(f"{expanded} is group/world-readable; run: chmod 600 {expanded}")
    with open(expanded, encoding="utf-8") as handle:
        return handle.read().strip()


# ---- magic packet ---------------------------------------------------------

def parse_mac(mac):
    digits = re.sub(r"[^0-9a-fA-F]", "", mac or "")
    if len(digits) != 12:
        raise ValueError(f"invalid MAC address: {mac!r}")
    return bytes.fromhex(digits)


def send_magic_packet(mac, broadcast, port):
    packet = b"\xff" * 6 + parse_mac(mac) * 16
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(packet, (broadcast, port))


def ping(host):
    """Return (reachable, latency_ms), or (None, None) when no host is set."""
    if not host:
        return None, None
    # Two quick probes so one dropped packet doesn't flip the PC to offline.
    result = subprocess.run(
        ["ping", "-c", "2", "-i", "0.2", "-W", "1", host],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    match = re.search(r"time[=<]\s*([0-9.]+)\s*ms", result.stdout)
    return result.returncode == 0, (float(match.group(1)) if match else None)


# ---- UpSnap (PocketBase) --------------------------------------------------

def http_json(url, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def upsnap_token(base, identity, password):
    if not identity:
        return None  # UpSnap may allow unauthenticated access to public devices
    body = {"identity": identity, "password": password}
    # Regular users first, then superusers (PocketBase >= 0.23), then legacy admins.
    for path in (
        "/api/collections/users/auth-with-password",
        "/api/collections/_superusers/auth-with-password",
        "/api/admins/auth-with-password",
    ):
        try:
            return http_json(base + path, "POST", body).get("token")
        except urllib.error.HTTPError:
            continue
    raise RuntimeError("UpSnap login failed")


def upsnap(args, action):
    base = args.upsnap_url.rstrip("/")
    if not base or not args.device_id:
        emit("error", "Set UpSnap URL and device ID")
    token = upsnap_token(base, args.identity, read_secret(args.password_file))
    if action in ("wake", "shutdown"):
        http_json(f"{base}/api/upsnap/{action}/{args.device_id}", token=token)
        emit("sent", f"{action.capitalize()} request sent via UpSnap")
    record = http_json(f"{base}/api/collections/devices/records/{args.device_id}", token=token)
    status = str(record.get("status", "")).lower()
    name = record.get("name", "")
    if status in ("online", "offline", "pending"):
        emit(status, name)
    emit("error", f"Unknown UpSnap status: {status or 'empty'}")


# ---- shutdown methods -----------------------------------------------------

def shutdown_ssh(args, host):
    if not host:
        emit("error", "Set a shutdown host or Host / IP for SSH")
    target = f"{args.shutdown_user}@{host}" if args.shutdown_user else host
    cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={TIMEOUT}",
        "-o", "StrictHostKeyChecking=accept-new",
        "-p", str(args.ssh_port),
    ]
    if args.ssh_key:
        cmd += ["-i", os.path.expanduser(args.ssh_key)]
    cmd += [target, args.shutdown_command or DEFAULT_SSH_COMMAND]
    ok, message = run(cmd)
    # The PC may drop the connection while powering off; that still counts.
    if ok or "closed by remote host" in message:
        emit("sent", f"Shutdown sent over SSH to {host}")
    emit("error", f"SSH: {message}")


def shutdown_windows(args, host):
    if not host:
        emit("error", "Set a shutdown host or Host / IP for Windows shutdown")
    if not args.shutdown_user:
        emit("error", "Set the Windows username for shutdown")
    domain, _, user = args.shutdown_user.rpartition("\\")
    lines = [f"username = {user}", f"password = {read_secret(args.shutdown_password_file)}"]
    if domain:
        lines.append(f"domain = {domain}")
    # Credentials go through a private temp file so they never show up in `ps`.
    with tempfile.NamedTemporaryFile("w", prefix="wake-pc-", suffix=".auth") as auth:
        auth.write("\n".join(lines) + "\n")
        auth.flush()
        ok, message = run([
            "net", "rpc", "shutdown", "-f", "-t", "0",
            "-C", "Shut down from Omarchy",
            "-I", host, "-A", auth.name,
        ])
    if ok:
        emit("sent", f"Shutdown sent to Windows PC {host}")
    emit("error", f"net rpc: {message}")


def shutdown_http(args):
    if not args.shutdown_url:
        emit("error", "Set the shutdown URL")
    req = urllib.request.Request(args.shutdown_url, method=args.shutdown_http_method)
    with urllib.request.urlopen(req, timeout=TIMEOUT):
        pass  # urlopen raises HTTPError for non-2xx responses
    emit("sent", "Shutdown request sent")


def shutdown_command(args, host):
    if not args.shutdown_command:
        emit("error", "Set the shutdown command")
    env = dict(os.environ, WAKE_PC_HOST=host, WAKE_PC_MAC=args.mac)
    ok, message = run(args.shutdown_command, timeout=30, env=env, shell=True)
    if ok:
        emit("sent", "Shutdown command ran")
    emit("error", f"Command: {message}")


def shutdown(args):
    host = args.shutdown_host or args.host
    method = args.shutdown_method
    if method == "upsnap":
        upsnap(args, "shutdown")
    elif method == "ssh":
        shutdown_ssh(args, host)
    elif method == "windows":
        shutdown_windows(args, host)
    elif method == "http":
        shutdown_http(args)
    elif method == "command":
        shutdown_command(args, host)
    emit("error", "Shutdown is not set up")


# ---- entry point ----------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "wake", "shutdown"])
    parser.add_argument("--mode", default="magic-packet", choices=["magic-packet", "upsnap"])
    parser.add_argument("--mac", default="")
    parser.add_argument("--broadcast", default="255.255.255.255")
    parser.add_argument("--port", type=int, default=9)
    parser.add_argument("--host", default="")
    parser.add_argument("--upsnap-url", default="")
    parser.add_argument("--device-id", default="")
    parser.add_argument("--identity", default="")
    parser.add_argument("--password-file", default="")
    parser.add_argument("--shutdown-method", default="none",
                        choices=["none", "upsnap", "ssh", "windows", "http", "command"])
    parser.add_argument("--shutdown-host", default="")
    parser.add_argument("--shutdown-user", default="")
    parser.add_argument("--shutdown-password-file", default="")
    parser.add_argument("--shutdown-command", default="")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--ssh-key", default="")
    parser.add_argument("--shutdown-url", default="")
    parser.add_argument("--shutdown-http-method", default="POST", choices=["GET", "POST"])
    # Read the config and drop it from the environment so ssh and the custom
    # shutdown command don't inherit it.
    config = json.loads(os.environ.pop("WAKE_PC_CONFIG", "") or "{}")
    config_args = [f"--{key}={value}" for key, value in config.items()]
    args = parser.parse_args(config_args + sys.argv[1:])

    try:
        if args.action == "shutdown":
            shutdown(args)

        if args.mode == "upsnap":
            upsnap(args, args.action)

        if args.action == "wake":
            send_magic_packet(args.mac, args.broadcast, args.port)
            emit("sent", f"Magic packet sent to {args.mac}")

        reachable, latency = ping(args.host)
        if reachable is None:
            emit("error", "Set a host/IP to check status")
        if reachable:
            emit("online", args.host, latency=latency)
        emit("offline", args.host)
    except urllib.error.HTTPError as exc:
        emit("error", f"HTTP {exc.code} {exc.reason}")
    except Exception as exc:  # noqa: BLE001 - always report back to the widget
        emit("error", str(exc))


if __name__ == "__main__":
    main()
