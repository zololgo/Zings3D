#!/usr/bin/env python3
"""Line-oriented JSON client for the Wings/Zings3D agent control plugin (wpc_agent)."""

from __future__ import annotations

import argparse
import json
import socket
import sys
from typing import Any


def send_cmd(host: str, port: int, payload: dict[str, Any], timeout: float = 120.0) -> dict[str, Any]:
    data = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(data)
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("connection closed before response")
            buf += chunk
        line, _ = buf.split(b"\n", 1)
    return json.loads(line.decode("utf-8"))


def run_session(host: str, port: int) -> list[dict[str, Any]]:
    steps: list[tuple[str, dict[str, Any]]] = [
        ("ping", {"op": "ping"}),
        ("new", {"op": "new"}),
        ("cube", {"op": "cube", "x": 2.0, "y": 2.0, "z": 2.0, "cuts": 1}),
        ("state", {"op": "state"}),
        ("select top (+Y)", {"op": "select", "mode": "face", "normal": [0, 1, 0], "threshold": 0.9}),
        ("extrude", {"op": "extrude", "axis": "normal", "distance": 0.5}),
        ("mode edge", {"op": "mode", "mode": "edge"}),
        ("bevel", {"op": "bevel", "distance": 0.08}),
        ("loop cut", {"op": "loop_cut"}),
        ("export obj", {"op": "export", "format": "obj", "path": "/tmp/wings_agent_test.obj"}),
        ("final state", {"op": "state"}),
    ]
    transcript: list[dict[str, Any]] = []
    for label, cmd in steps:
        resp = send_cmd(host, port, cmd)
        entry = {"step": label, "request": cmd, "response": resp}
        transcript.append(entry)
        print(f"=== {label} ===")
        print(json.dumps(entry, indent=2))
        if not resp.get("ok", False):
            raise SystemExit(f"Step failed: {label}")
    return transcript


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=51337)
    parser.add_argument("--cmd", help='Single JSON command, e.g. \'{"op":"state"}\'')
    parser.add_argument("--session", action="store_true", help="Run the built-in modeling session test")
    args = parser.parse_args()

    if args.session:
        run_session(args.host, args.port)
        return
    if args.cmd:
        payload = json.loads(args.cmd)
        print(json.dumps(send_cmd(args.host, args.port, payload), indent=2))
        return
    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
