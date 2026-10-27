# Wings agent control protocol

Zings3D/Wings loads the `wpc_agent` plugin on startup (unless `WINGS_AGENT_DISABLE=1`). It listens on **127.0.0.1** for TCP connections and speaks **newline-delimited JSON** (one request per line, one response per line).

Default port: **51337** (`WINGS_AGENT_PORT` overrides).

## Request shape

Every request is a JSON object with an `"op"` field:

```json
{"op": "ping"}
```

## Response shape

Success:

```json
{"ok": true, "op": "state", "selection_mode": "face", "objects": [...]}
```

Failure:

```json
{"ok": false, "op": "extrude", "error": "..."}
```

## Operations

| op | Fields | Notes |
|----|--------|-------|
| `ping` | — | Health check |
| `state` | — | Objects (id, name, v/e/f counts, bbox), selection mode, selection |
| `dump_mesh` | `object` (optional id) | Raw vertex positions and face index lists for one object |
| `new` | — | New scene (no save prompt) |
| `undo` / `redo` | — | Edit stack |
| `mode` | `mode`: `vertex` \| `edge` \| `face` \| `body` | Selection mode |
| `cube` | `x`, `y`, `z`, `cuts` | Dialog-free n-cube primitive |
| `select` | `mode`, `ids` + optional `object`, **or** `normal` + `threshold` | Face selection by ids or by normal direction |
| `extrude` | `distance`, optional `axis` (`normal`, `x`, `y`, `z`) | Region extrude + numeric move |
| `bevel` | `distance` | Edge or face bevel (current mode) |
| `loop_cut` | — | Loop cut on current edge selection |
| `move` | `distance`, optional `axis` | Numeric move drag |
| `scale` | `factor` | Uniform scale from selection center |
| `export` | `format` (`obj`, `fbx`), `path` | Writes file without a dialog |

## Example session

With Wings running and the listener active:

```bash
python3 tools/wings_agent_client.py --session
```

Single command:

```bash
python3 tools/wings_agent_client.py --cmd '{"op":"state"}'
```

## Client library

Use any TCP client. Python helper: `tools/wings_agent_client.py`.

## Limitations

- Listener is **localhost only** (not authenticated).
- `select` by normal is implemented for **faces** only.
- Interactive-only tools (tweak, pick-in-viewport) are not exposed.
- Export uses the same options as a silent Wavefront/FBX export (no material dialogs).
- Numeric ops finish drags programmatically via `wings_drag:apply_numeric/2` (same code path as numeric entry, not mouse motion).
