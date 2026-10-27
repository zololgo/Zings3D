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
| `mode` | `mode`: `vertex` \| `edge` \| `face` \| `body` | Changes mode and **converts** the current selection (same as the UI) |
| `clear_select` | — | Clears selection (use before screenshots) |
| `frame` | — | View → Frame (fit selection/objects in the viewport) |
| `cube` | `x`, `y`, `z`, `cuts` | Dialog-free n-cube primitive |
| `select` | `mode`, `ids` + optional `object`, **or** `normal` + `threshold` | Face selection by ids or by normal direction |
| `extrude` | `distance`, optional `axis` (`normal`, `x`, `y`, `z`) | Region extrude + numeric move |
| `bevel` | `distance` | Edge or face bevel (current mode) |
| `cut` | optional `segments` (integer ≥2) | **Default (no `segments`):** same as **C** hotkey — `{edge,connect}` or `{vertex,connect}` (midpoint cut + connecting edges, one object). With `segments`: `{edge,{cut,N}}` only (split into N parts, no connect; edge mode). |
| `connect` | optional `variant` | Extra connect modes (`edge_multiple`, `vertex_cuts`, …). Plain edge/vertex connect is usually **`cut`** without args. |
| `select_edge_ring` | — | `{select,{edge_loop,edge_ring}}` — grow edge selection to ring |
| `edge_ring_cut` | optional `expand_ring` (default true) | `select_edge_ring` then **`cut`** (in-object ring loop) |
| `loop_cut` | — | `{edge,loop_cut}` — **splits into two objects** (unlike C / `cut`) |
| `inset` | `distance`, optional `type` (`inset_faces`, `inset_region`, `offset_region`) | Face inset via `wpc_inset` (face mode; numeric inset drag) |
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

## Wings command tuples (reference)

| User action | Mode | Tuple (via `wings:command/2`) |
|-------------|------|----------------------------------|
| **C** (cut + connect) | edge | `{edge, connect}` |
| **C** | vertex | `{vertex, connect}` |
| **2**–**0** (N equal segments) | edge | `{edge, {cut, N}}` (N=2..10) |
| Loop Cut | edge | `{edge, loop_cut}` |
| Edge ring | edge | `{select, {edge_loop, edge_ring}}` |

Hotkeys are defined in `src/wings_hotkey.erl` (default bindings; no repo-specific override found).

## Verified runs

See `tools/agent_e2e_transcript.json` for a full request/response log (standard session + house modeling test).

## Limitations

- Listener is **localhost only** (not authenticated).
- `select` by normal is implemented for **faces** only (uses CCW face normals).
- Interactive-only tools (tweak, pick-in-viewport) are not exposed.
- Export uses the same options as a silent Wavefront/FBX export (no material dialogs).
- Numeric ops finish drags via `wings_drag:apply_numeric/2`; `skip` (and trailing) drag units default to `0.0`.
- `inset` relative mode uses percent units internally; pass `distance` accordingly (0–1 for relative inset).
