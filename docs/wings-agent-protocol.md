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

Some ops merge extra fields into the success payload (e.g. `uv_project` returns `uv_bounds`, `mat_info` returns `materials`).

## Operations (summary)

| op | Fields | Notes |
|----|--------|-------|
| `ping` | — | Health check |
| `state` | — | Objects (id, name, v/e/f counts, bbox), selection mode, selection |
| `dump_mesh` | `object` (optional id) | Raw vertex positions and face index lists for one object |
| `new` | — | New scene (no save prompt) |
| `undo` / `redo` | — | Edit stack |
| `mode` | `mode`: `vertex` \| `edge` \| `face` \| `body` | Changes mode and **converts** the current selection (same as the UI) |
| `clear_select` | — | Clears selection |
| `frame` | — | View → Frame |
| `view` | optional prefs (see below) | Viewport preview prefs + returns `mat_info` fields |
| `mat_info` | — | Material list, map keys, texture preview prefs (no geometry change) |
| `cube` | `x`, `y`, `z`, `cuts`, optional `mov_x/y/z`, `ground` | Dialog-free n-cube |
| `cylinder` | see [Primitives](#primitives) | `wpc_cylinder` shape |
| `geodome` | see [Primitives](#primitives) | `wpc_geodome` shape; optional post `scale` |
| `rename` | `name`, optional `object` | Rename one object |
| `select` | `mode`, `ids` + optional `object`, **`all`**, or **`normal`** + `threshold` + optional `object` | Face selection by ids, all elements, or normal |
| `extrude` | `distance`, optional `axis` | Region extrude + numeric move |
| `bevel` | `distance` | Edge or face bevel |
| `cut` | optional `segments` (≥2, default 2) | `{edge,{cut,N}}` — split edges (not Connect) |
| `connect` | optional `variant` | **C hotkey** — `{edge,connect}` / `{vertex,connect}` |
| `select_ring` | — | `{select,{edge_loop,edge_ring}}` (hotkey **G**) |
| `select_edge_ring` | — | Alias of `select_ring` |
| `edge_ring_connect` | optional `expand_ring` (default true) | `select_ring` then `connect` |
| `edge_ring_cut` | optional `expand_ring` | Alias of `edge_ring_connect` |
| `loop_cut` | — | `{edge,loop_cut}` — two objects |
| `inset` | `distance`, optional `type` | Face inset |
| `move` | `distance`, optional `axis` | Numeric move |
| `scale` | `factor`, optional `axis` | Scale (see [Transform](#transform)) |
| `rotate` | `angle`, optional `axis` | Rotate around axis through selection center |
| `material` | see [Materials](#materials) | Add/load material via `wings_material:add_materials` |
| `uv_project` | see [UV](#uv) | Built-in **planar** projection of selected faces |
| `uv_transform` | see [UV](#uv) | Scale/offset or `rect` remap of existing UVs |
| `uv_dump` | — | UV stats per object and current selection |
| `export` | `format`, `path`, optional `include_uvs` (default **true** for OBJ) | Silent export |

## Primitives

### `cube`

```json
{"op":"cube","x":2,"y":2,"z":2,"cuts":1,"mov_x":0,"mov_y":0,"mov_z":0,"ground":true}
```

### `cylinder`

```json
{"op":"cylinder","sections":8,"height":2,"top_radius":0.5,"bottom_radius":0.5,
 "top_x":0.5,"top_z":0.5,"bottom_x":0.5,"bottom_z":0.5,
 "mov_x":0,"mov_y":0,"mov_z":0,"ground":true}
```

`top_radius` / `bottom_radius` set both `top_x`/`top_z` and `bottom_x`/`bottom_z` when those are omitted.

### `geodome`

```json
{"op":"geodome","resolution":1,"base":"icosahedron","algorithm":"frequency",
 "spherize":true,"dome":false,"scale":1,"mov_x":0,"mov_y":0,"mov_z":0,"ground":false}
```

`base`: `icosahedron` \| `octahedron` \| `tetrahedron` (atoms as JSON strings).  
If `scale` ≠ 1, the new body is selected and uniformly scaled after creation.

### `rename`

```json
{"op":"rename","object":1,"name":"TreeTrunk"}
```

## Selection

### Select all in mode

```json
{"op":"select","mode":"face","object":1,"all":true}
```

### Select by normal (optional object filter)

All objects with matching faces:

```json
{"op":"select","mode":"face","normal":[0,1,0],"threshold":0.9}
```

Single object only:

```json
{"op":"select","mode":"face","object":1,"normal":[0,0,1],"threshold":0.9}
```

## Transform

### `scale` axes

`axis` (default `uniform`): `uniform` \| `x` \| `y` \| `z` \| `radial_x` \| `radial_y` \| `radial_z` \| `radial` (radial around Y).

```json
{"op":"scale","factor":0.5,"axis":"y"}
```

```json
{"op":"scale","factor":1.2,"axis":"radial_z"}
```

### `rotate`

```json
{"op":"rotate","angle":45,"axis":"y"}
```

`axis`: `x` \| `y` \| `z` \| `normal` \| `uniform` (same parsing as move).

## Materials

### `material`

Creates or replaces a material (reloads diffuse map if `map_kd` is set). Optionally assigns to current selection.

```json
{"op":"material","name":"Bark","r":0.4,"g":0.25,"b":0.1,"a":1,
 "map_kd":"/path/to/bark.png","assign":true}
```

Without `map_kd`, solid OpenGL diffuse color only. `assign`: default `true`.

### `mat_info`

```json
{"op":"mat_info"}
```

Response includes `materials` (name, `map_keys`, `has_diffuse_map`) and preview prefs `filter_texture`, `show_textures`, `workmode`.

### `view`

Sets viewport preview preferences (boolean fields; omit to leave unchanged):

| Field | Pref | Typical use |
|-------|------|-------------|
| `filter_texture` | nearest filtering | `false` for pixel-art textures |
| `show_textures` | show textured shading | `true` |
| `workmode` | unlit / work mode | `true` for flat preview |
| `show_edges` | edge overlay | `true` |

```json
{"op":"view","show_textures":true,"workmode":true,"filter_texture":false}
```

Also returns the same material/pref summary as `mat_info`.

## UV

**Note:** `uv_project` is a **simple built-in planar projection** (world-axis or cylindrical `atan2`). A follow-up should route this through the repo owner’s **AutoUV planar projection** command for parity with the interactive UV workflow.

Requires **face mode** and a non-empty face selection.

### `uv_project`

| Field | Default | Meaning |
|-------|---------|---------|
| `axis` | `"z"` | `"x"` \| `"y"` \| `"z"` \| `"cylinder"` |
| `normalize` | `true` | Fit projected coords to 0..1 before optional `rect` |
| `rect` | — | `[u0,v0,u1,v1]` — place normalized island in UV rectangle |

```json
{"op":"mode","mode":"face"}
```

```json
{"op":"select","mode":"face","object":1,"all":true}
```

```json
{"op":"uv_project","axis":"y","normalize":true,"rect":[0,0,1,1]}
```

Response adds `uv_bounds`, `uv_count`, `axis`.

### `uv_transform`

Adjust existing per-corner UVs (run `uv_project` first if needed).

| Field | Meaning |
|-------|---------|
| `u`, `v` | Translation |
| `scale_u`, `scale_v` | Scale (default 1) |
| `normalize` | Normalize selection UVs before transform |
| `rect` | If set, maps normalized 0..1 into this rectangle (overrides u/v/scale) |

```json
{"op":"uv_transform","scale_u":0.5,"scale_v":0.5,"u":0.25,"v":0.25}
```

### `uv_dump`

```json
{"op":"uv_dump"}
```

Returns per-object `uv_count`, `uv_bounds`, `has_uvs`, plus selection UV summary.

### Export with UVs

```json
{"op":"export","format":"obj","path":"/tmp/model.obj","include_uvs":true}
```

Default `include_uvs` is **true** for Wavefront OBJ. FBX export ignores this flag (plugin attributes unchanged).

## Example session

```bash
python3 tools/wings_agent_client.py --session
python3 tools/wings_agent_client.py --cmd '{"op":"state"}'
```

Python payload helpers (optional): `tools/wings_agent_client.py` — see `op_*` functions.

## Wings command tuples (reference)

| User action | Mode | Tuple |
|-------------|------|--------|
| **C** (Connect) | edge | `{edge, connect}` |
| **C** (Connect) | vertex | `{vertex, connect}` |
| **2**–**0** (Cut N) | edge | `{edge, {cut, N}}` |
| Loop Cut | edge | `{edge, loop_cut}` |
| Edge ring | edge | `{select, {edge_loop, edge_ring}}` ( **G** ) |

Hotkeys: `src/wings_hotkey.erl` (defaults).

## Verified runs

See `tools/agent_e2e_transcript.json` for modeling session + house test logs.

## Limitations

- Listener is **localhost only** (not authenticated).
- `select` by normal is **face mode** only.
- `uv_project` is agent-side planar math, not AutoUV yet.
- Interactive-only tools are not exposed.
- Numeric ops use `wings_drag:apply_numeric/2`; trailing/`skip` units default to `0.0`.
