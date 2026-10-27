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
    return run_steps(host, port, steps)


def run_house(host: str, port: int) -> list[dict[str, Any]]:
    steps: list[tuple[str, dict[str, Any]]] = [
        ("house/new", {"op": "new"}),
        ("house/cube", {"op": "cube", "x": 4.0, "y": 2.5, "z": 3.0, "cuts": 1}),
        ("house/state0", {"op": "state"}),
        ("house/select_top", {"op": "select", "mode": "face", "normal": [0, 1, 0], "threshold": 0.9}),
        ("house/extrude_roof", {"op": "extrude", "axis": "normal", "distance": 1.2}),
        ("house/scale_roof", {"op": "scale", "factor": 0.35}),
        ("house/state_roof", {"op": "state"}),
        ("house/select_front", {"op": "select", "mode": "face", "normal": [0, 0, 1], "threshold": 0.9}),
        ("house/extrude_front", {"op": "extrude", "axis": "normal", "distance": 0.15}),
        ("house/scale_front", {"op": "scale", "factor": 0.55}),
        ("house/state_front", {"op": "state"}),
        ("house/move_front_in", {"op": "move", "axis": "z", "distance": -0.25}),
        ("house/state_final", {"op": "state"}),
        ("house/export_obj", {"op": "export", "format": "obj", "path": "/tmp/wings_agent_house.obj"}),
        ("house/export_fbx", {"op": "export", "format": "fbx", "path": "/tmp/wings_agent_house.fbx"}),
        ("house/frame", {"op": "frame"}),
    ]
    out = [{"section": "house_test"}]
    out.extend(run_steps(host, port, steps, stop_on_error=True))
    return out


def run_steps(
    host: str,
    port: int,
    steps: list[tuple[str, dict[str, Any]]],
    *,
    stop_on_error: bool = True,
) -> list[dict[str, Any]]:
    transcript: list[dict[str, Any]] = []
    for label, cmd in steps:
        resp = send_cmd(host, port, cmd)
        entry = {"step": label, "request": cmd, "response": resp}
        transcript.append(entry)
        print(f"=== {label} ===")
        print(json.dumps(entry, indent=2))
        if stop_on_error and not resp.get("ok", False):
            raise SystemExit(f"Step failed: {label}")
    return transcript


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=51337)
    parser.add_argument("--cmd", help='Single JSON command, e.g. \'{"op":"state"}\'')
    parser.add_argument("--session", action="store_true", help="Run the built-in modeling session test")
    parser.add_argument("--house", action="store_true", help="Run the house modeling test (after --session or alone)")
    parser.add_argument("--all", action="store_true", help="Run --session then --house")
    args = parser.parse_args()

    if args.all:
        run_session(args.host, args.port)
        run_house(args.host, args.port)
        return
    if args.session:
        run_session(args.host, args.port)
        return
    if args.house:
        run_house(args.host, args.port)
        return
    if args.cmd:
        payload = json.loads(args.cmd)
        print(json.dumps(send_cmd(args.host, args.port, payload), indent=2))
        return
    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
