#!/usr/bin/env python3
"""Mesh analysis client for Wings/Zings3D agent `mesh_report` op.

Calls the agent for topology/geometry/UV health, then adds:
  - palette swatch checks (from colorpoly generator config)
  - shape metrics vs an optional spec JSON
  - human-readable summary + full JSON
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

# Allow running from repo root or tools/
_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from wings_agent_client import op_mesh_report, send_cmd  # noqa: E402

# --- Palette layout (derived from generate_palette.py + config) -----------------

BASE_PALETTES = {
    "basic": ("red", "yellow", "blue", "grey"),
    "extended": ("red", "orange", "yellow", "green", "cyan", "blue", "purple", "grey"),
    "full": (
        "red",
        "orange",
        "yellow",
        "lime",
        "green",
        "cyan",
        "teal",
        "blue",
        "purple",
        "pink",
        "grey",
    ),
}


def build_neighbor_pairs(base_order: list[str] | tuple[str, ...]) -> list[tuple[str, str]]:
    chromatic = [n for n in base_order if n != "grey"]
    if len(chromatic) < 2:
        return []
    pairs = [(chromatic[i], chromatic[i + 1]) for i in range(len(chromatic) - 1)]
    pairs.append((chromatic[-1], chromatic[0]))
    return pairs


def load_palette_layout(config_path: str | Path) -> dict[str, Any]:
    """Reproduce swatch geometry from generate_palette.py / config_small.json."""
    cfg = json.loads(Path(config_path).read_text())
    steps = int(cfg.get("steps", 10))
    swatch_size = int(cfg.get("swatch_size", 1))
    grid = max(0, int(cfg.get("grid_line_width", 0)))
    pad = max(0, int(cfg.get("padding_width", 0)))
    base_palette = (cfg.get("base_palette") or "full").strip().lower()
    base_order = list(BASE_PALETTES.get(base_palette, BASE_PALETTES["full"]))
    pairs = build_neighbor_pairs(base_order)
    block = swatch_size * steps
    seg_w = block + 2 * pad
    row_w = 2 * seg_w + grid
    row_band_h = seg_w
    num_rows = len(pairs)
    img_w = row_w + 2 * grid
    img_h = num_rows * row_band_h + max(0, num_rows - 1) * grid + 2 * grid
    swatches: list[dict[str, Any]] = []
    for row_i, (c1, c2) in enumerate(pairs):
        y0 = grid + row_i * (row_band_h + grid)
        # left segment: grey -> c1 ; right segment: c1 -> c2
        for seg_i, (seg_name, c_left, c_right) in enumerate(
            [("grey_to_c1", "grey", c1), ("c1_to_c2", c1, c2)]
        ):
            x0 = grid + seg_i * (seg_w + grid)
            # Interior of the color block (excluding pad)
            ix0, iy0 = x0 + pad, y0 + pad
            ix1, iy1 = ix0 + block, iy0 + block
            swatches.append(
                {
                    "row": row_i,
                    "segment": seg_i,
                    "segment_name": seg_name,
                    "c1": c1,
                    "c2": c2,
                    "label": f"row{row_i}:{c1}/{c2}:{seg_name}",
                    "row_color": c1,  # user-facing: row keyed by left chromatic
                    "outer_px": [x0, y0, x0 + seg_w, y0 + row_band_h],
                    "interior_px": [ix0, iy0, ix1, iy1],
                    "pad": pad,
                    "block": block,
                }
            )
    return {
        "config": {
            "steps": steps,
            "swatch_size": swatch_size,
            "grid_line_width": grid,
            "padding_width": pad,
            "base_palette": base_palette,
            "img_w": img_w,
            "img_h": img_h,
        },
        "pairs": [{"row": i, "c1": a, "c2": b} for i, (a, b) in enumerate(pairs)],
        "swatches": swatches,
        "palette_image": cfg.get("output"),
    }


def uv_bbox_to_px(bbox: list[float], img_w: float, img_h: float) -> list[float]:
    """UV bounds [u0,u1,v0,v1] → pixel rect [x0,y0,x1,y1] (V flips: v=1 top)."""
    u0, u1, v0, v1 = bbox
    x0, x1 = min(u0, u1) * img_w, max(u0, u1) * img_w
    # Wings/OBJ: v=0 at bottom; image y=0 at top
    y_top = (1.0 - max(v0, v1)) * img_h
    y_bot = (1.0 - min(v0, v1)) * img_h
    return [x0, y_top, x1, y_bot]


def classify_island(
    bbox_uv: list[float],
    layout: dict[str, Any],
    margin_px: float = 1.0,
) -> dict[str, Any]:
    cfg = layout["config"]
    img_w, img_h = cfg["img_w"], cfg["img_h"]
    rect = uv_bbox_to_px(bbox_uv, img_w, img_h)
    x0, y0, x1, y1 = rect
    cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    hits: list[dict[str, Any]] = []
    for sw in layout["swatches"]:
        ix0, iy0, ix1, iy1 = sw["interior_px"]
        # overlap with interior
        ox0, oy0 = max(x0, ix0), max(y0, iy0)
        ox1, oy1 = min(x1, ix1), min(y1, iy1)
        if ox0 < ox1 and oy0 < oy1:
            # margin: island must stay ≥ margin inside interior
            inside_margin = (
                x0 >= ix0 + margin_px
                and y0 >= iy0 + margin_px
                and x1 <= ix1 - margin_px
                and y1 <= iy1 - margin_px
            )
            hits.append(
                {
                    "row": sw["row"],
                    "segment": sw["segment"],
                    "row_color": sw["row_color"],
                    "c1": sw["c1"],
                    "c2": sw["c2"],
                    "segment_name": sw["segment_name"],
                    "label": sw["label"],
                    "inside_margin": inside_margin,
                    "margin_px": margin_px,
                }
            )
    # also check outer pads / straddling
    straddles = len(hits) > 1
    in_pad_or_gap = len(hits) == 0
    primary = None
    if hits:
        # pick swatch containing center, else largest overlap proxy = first
        for h in hits:
            sw = layout["swatches"][h["row"] * 2 + h["segment"]]
            ix0, iy0, ix1, iy1 = sw["interior_px"]
            if ix0 <= cx <= ix1 and iy0 <= cy <= iy1:
                primary = h
                break
        if primary is None:
            primary = hits[0]
    return {
        "bbox_uv": bbox_uv,
        "bbox_px": rect,
        "center_px": [cx, cy],
        "swatches_hit": hits,
        "primary": primary,
        "straddles_swatches": straddles,
        "in_pad_or_gap": in_pad_or_gap,
        "stays_inside_margin": bool(primary and primary["inside_margin"] and not straddles),
    }


def sample_uv_colors(
    uvs: list[tuple[float, float]],
    image_path: str | Path | None,
) -> dict[str, Any] | None:
    if not image_path or not Path(image_path).is_file():
        return None
    try:
        from PIL import Image
    except ImportError:
        return None
    im = Image.open(image_path).convert("RGB")
    w, h = im.size
    pix = im.load()
    colors: list[tuple[int, int, int]] = []
    for u, v in uvs:
        x = int(max(0, min(w - 1, round(u * (w - 1)))))
        y = int(max(0, min(h - 1, round((1.0 - v) * (h - 1)))))
        colors.append(pix[x, y])
    if not colors:
        return None
    n = len(colors)
    avg = [sum(c[i] for c in colors) / n for i in range(3)]
    mn = [min(c[i] for c in colors) for i in range(3)]
    mx = [max(c[i] for c in colors) for i in range(3)]
    return {"average_rgb": avg, "min_rgb": mn, "max_rgb": mx, "samples": n}


# --- Shape metrics -------------------------------------------------------------

def part_dims(obj: dict[str, Any]) -> dict[str, float]:
    size = obj.get("bbox", {}).get("size") or [0, 0, 0]
    return {"x": float(size[0]), "y": float(size[1]), "z": float(size[2])}


def part_center(obj: dict[str, Any]) -> list[float]:
    return list(obj.get("bbox", {}).get("center") or [0, 0, 0])


def sweep_angle_deg(vertices: list[list[float]], lateral_axis: str = "z") -> float | None:
    """Leading-edge sweep relative to lateral axis for wing-like parts.

    Uses the convex outline in the XZ (or XY) plane: angle of the line from
    the most-root lateral tip to the most-forward tip, measured from the
    lateral axis toward +X (aft/forward fuselage axis). Returns degrees.
    """
    if not vertices or len(vertices) < 3:
        return None
    # Assume ship length along +X, span along ±Z (or ±Y if lateral_axis=y)
    lat_i = {"x": 0, "y": 1, "z": 2}[lateral_axis]
    fwd_i = 0  # X
    pts = [(float(v[fwd_i]), float(v[lat_i])) for v in vertices]
    # Root = smallest |lateral|, tip = largest |lateral|
    tip = max(pts, key=lambda p: abs(p[1]))
    # Leading candidates: among the outer half-span, the most forward (min X)
    span = max(abs(p[1]) for p in pts) or 1.0
    outer = [p for p in pts if abs(p[1]) >= 0.45 * span]
    if not outer:
        outer = pts
    leading = min(outer, key=lambda p: p[0])
    root_side = min(pts, key=lambda p: abs(p[1]))
    dx = leading[0] - root_side[0]
    dz = leading[1] - root_side[1]
    if abs(dz) < 1e-9 and abs(dx) < 1e-9:
        return None
    # Angle from pure lateral (0°) toward aft/forward: atan2(|dx|, |dz|)
    ang = math.degrees(math.atan2(abs(dx), abs(dz)))
    return ang


def relative_placement(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    ca, cb = part_center(a), part_center(b)
    return {
        "delta": [ca[i] - cb[i] for i in range(3)],
        "above": ca[1] > cb[1],
        "below": ca[1] < cb[1],
        "behind": ca[0] > cb[0],  # +X = aft for this ship convention
        "ahead": ca[0] < cb[0],
        "right": ca[2] > cb[2],
        "left": ca[2] < cb[2],
    }


def compute_shape_metrics(
    objects: list[dict[str, Any]],
    main_name: str = "fuselage",
    dump_meshes: dict[str, list[list[float]]] | None = None,
) -> dict[str, Any]:
    by_name = {o["name"]: o for o in objects}
    main = by_name.get(main_name)
    main_dims = part_dims(main) if main else {"x": 1, "y": 1, "z": 1}
    length = max(main_dims["x"], 1e-9)
    # Wingspan: max Z extent across wing_* parts, else whole scene
    wing_names = [n for n in by_name if n.startswith("wing")]
    if wing_names:
        zmin = min(by_name[n]["bbox"]["min"][2] for n in wing_names)
        zmax = max(by_name[n]["bbox"]["max"][2] for n in wing_names)
        wingspan = zmax - zmin
    else:
        zmin = min(o["bbox"]["min"][2] for o in objects)
        zmax = max(o["bbox"]["max"][2] for o in objects)
        wingspan = zmax - zmin

    parts: dict[str, Any] = {}
    for name, obj in by_name.items():
        d = part_dims(obj)
        entry: dict[str, Any] = {
            "dims": d,
            "center": part_center(obj),
            "aspect_xz": d["x"] / max(d["z"], 1e-9),
            "aspect_xy": d["x"] / max(d["y"], 1e-9),
            "aspect_zy": d["z"] / max(d["y"], 1e-9),
            "rel_to_main": {
                "x": d["x"] / length,
                "y": d["y"] / max(main_dims["y"], 1e-9),
                "z": d["z"] / max(main_dims["z"], 1e-9),
            },
        }
        if main and name != main_name:
            entry["placement_vs_main"] = relative_placement(obj, main)
        if dump_meshes and name in dump_meshes and name.startswith("wing"):
            entry["sweep_deg"] = sweep_angle_deg(dump_meshes[name], "z")
        parts[name] = entry

    ratios = {
        "wingspan/length": wingspan / length,
        "wingspan": wingspan,
        "length": length,
    }
    return {"main": main_name, "parts": parts, "ratios": ratios}


def check_spec(metrics: dict[str, Any], spec: dict[str, Any]) -> list[dict[str, Any]]:
    """Spec keys: part name -> {metric: [lo, hi]}, or 'ratio' -> {name: [lo,hi]}."""
    results: list[dict[str, Any]] = []
    parts = metrics.get("parts", {})
    ratios = metrics.get("ratios", {})

    def check_range(label: str, value: float | None, lo_hi: list[float]) -> None:
        if value is None:
            results.append({"check": label, "pass": False, "value": None, "expected": lo_hi, "reason": "missing"})
            return
        lo, hi = float(lo_hi[0]), float(lo_hi[1])
        ok = lo <= value <= hi
        results.append({"check": label, "pass": ok, "value": value, "expected": [lo, hi]})

    for key, rules in spec.items():
        if key == "ratio":
            for rname, lo_hi in rules.items():
                check_range(f"ratio.{rname}", ratios.get(rname), lo_hi)
            continue
        if key == "placement":
            # {"engine_L": {"above": "fuselage"}, ...}
            for part, rels in rules.items():
                p = parts.get(part)
                if not p:
                    results.append({"check": f"placement.{part}", "pass": False, "reason": "missing part"})
                    continue
                for rel, other in rels.items():
                    if other == metrics.get("main"):
                        place = p.get("placement_vs_main") or {}
                        ok = bool(place.get(rel))
                        results.append(
                            {
                                "check": f"placement.{part}.{rel}.{other}",
                                "pass": ok,
                                "value": place.get(rel),
                                "expected": True,
                            }
                        )
                    else:
                        o = parts.get(other)
                        if not o:
                            results.append(
                                {"check": f"placement.{part}.{rel}.{other}", "pass": False, "reason": "missing other"}
                            )
                            continue
                        # rebuild relative
                        fake_a = {"bbox": {"center": p["center"]}}
                        fake_b = {"bbox": {"center": o["center"]}}
                        place = relative_placement(fake_a, fake_b)
                        ok = bool(place.get(rel))
                        results.append(
                            {
                                "check": f"placement.{part}.{rel}.{other}",
                                "pass": ok,
                                "value": place.get(rel),
                                "expected": True,
                            }
                        )
            continue
        # part metrics
        part = parts.get(key)
        if not isinstance(rules, dict):
            continue
        if not part:
            results.append({"check": key, "pass": False, "reason": "missing part"})
            continue
        for metric, lo_hi in rules.items():
            if metric == "sweep_deg":
                check_range(f"{key}.sweep_deg", part.get("sweep_deg"), lo_hi)
            elif metric in ("aspect_xz", "aspect_xy", "aspect_zy"):
                check_range(f"{key}.{metric}", part.get(metric), lo_hi)
            elif metric in ("x", "y", "z"):
                check_range(f"{key}.dim_{metric}", (part.get("dims") or {}).get(metric), lo_hi)
            elif metric.startswith("rel_"):
                axis = metric.split("_", 1)[1]
                check_range(f"{key}.{metric}", (part.get("rel_to_main") or {}).get(axis), lo_hi)
            else:
                check_range(f"{key}.{metric}", part.get(metric), lo_hi)
    return results


# --- Agent I/O -----------------------------------------------------------------

def fetch_mesh_report(
    host: str,
    port: int,
    objects: list[int] | None = None,
    **params: Any,
) -> dict[str, Any]:
    payload = op_mesh_report(objects=objects, **params)
    return send_cmd(host, port, payload)


def fetch_dump_vertices(host: str, port: int, obj_id: int) -> list[list[float]]:
    resp = send_cmd(host, port, {"op": "dump_mesh", "object": obj_id})
    if not resp.get("ok"):
        return []
    return resp.get("vertices") or []


def analyze(
    report: dict[str, Any],
    *,
    palette_config: str | Path | None = None,
    palette_image: str | Path | None = None,
    margin_px: float = 1.0,
    spec: dict[str, Any] | None = None,
    dump_meshes: dict[str, list[list[float]]] | None = None,
    main_part: str = "fuselage",
) -> dict[str, Any]:
    objects = report.get("objects") or []
    layout = load_palette_layout(palette_config) if palette_config else None
    img = palette_image or (layout or {}).get("palette_image")

    palette_checks: list[dict[str, Any]] = []
    if layout:
        for obj in objects:
            uv = obj.get("uv") or {}
            islands = uv.get("islands") or []
            # If no islands but has overall bounds, treat as one island
            if not islands and uv.get("uv_bounds"):
                islands = [{"faces": obj.get("faces", 0), "bbox": uv["uv_bounds"], "outside_01": False}]
            for i, isl in enumerate(islands):
                bbox = isl.get("bbox")
                if not bbox:
                    continue
                # encode_uv_bounds returns [u0,u1,v0,v1]
                cls = classify_island(bbox, layout, margin_px=margin_px)
                # sample colors at island bbox corners + center in UV
                u0, u1, v0, v1 = bbox
                sample_uvs = [
                    ((u0 + u1) * 0.5, (v0 + v1) * 0.5),
                    (u0, v0),
                    (u1, v0),
                    (u0, v1),
                    (u1, v1),
                ]
                colors = sample_uv_colors(sample_uvs, img)
                palette_checks.append(
                    {
                        "object": obj.get("name"),
                        "object_id": obj.get("id"),
                        "island_index": i,
                        "faces": isl.get("faces"),
                        **cls,
                        "sampled_color": colors,
                    }
                )

    shape = compute_shape_metrics(objects, main_name=main_part, dump_meshes=dump_meshes)
    spec_results = check_spec(shape, spec) if spec else []

    return {
        "agent_report": report,
        "palette_layout": layout,
        "palette_checks": palette_checks,
        "shape_metrics": shape,
        "spec": spec,
        "spec_results": spec_results,
    }


def summarize(analysis: dict[str, Any]) -> str:
    lines: list[str] = []
    report = analysis.get("agent_report") or {}
    objects = report.get("objects") or []
    errors = report.get("errors") or []
    lines.append(f"mesh_report: {len(objects)} object(s), {len(errors)} error(s)")
    for obj in objects:
        topo = obj.get("topology") or {}
        geom = obj.get("geometry") or {}
        uv = obj.get("uv") or {}
        issues = []
        if topo.get("open_edges"):
            issues.append(f"open_edges={topo['open_edges']}")
        if topo.get("non_manifold_edges"):
            issues.append(f"non_manifold={topo['non_manifold_edges']}")
        if topo.get("degenerate_faces"):
            issues.append(f"degenerate={topo['degenerate_faces']}")
        if topo.get("ngons"):
            issues.append(f"ngons={topo['ngons']}")
        if topo.get("coincident_vertices"):
            issues.append(f"coincident_v={topo['coincident_vertices']}")
        if geom.get("non_planar_faces"):
            issues.append(
                f"non_planar={geom['non_planar_faces']} (max_rel={geom.get('max_planarity_deviation'):.4f})"
            )
        if geom.get("inverted_normals"):
            issues.append(f"inverted_n={geom['inverted_normals']}")
        if geom.get("winding_inconsistencies"):
            issues.append(f"winding={geom['winding_inconsistencies']}")
        if uv.get("faces_without_uvs"):
            issues.append(f"no_uv_faces={uv['faces_without_uvs']}")
        if uv.get("uvs_outside_01"):
            issues.append(f"uv_outside={uv['uvs_outside_01']}")
        vol = obj.get("volume")
        vol_s = f"{vol:.4f}" if isinstance(vol, (int, float)) else "n/a"
        size = obj.get("bbox", {}).get("size", [0, 0, 0])
        flag = "OK" if not issues else "ISSUES"
        lines.append(
            f"  [{flag}] {obj.get('name')} id={obj.get('id')} "
            f"v/e/f={obj.get('vertices')}/{obj.get('edges')}/{obj.get('faces')} "
            f"size=({size[0]:.3f},{size[1]:.3f},{size[2]:.3f}) "
            f"area={obj.get('surface_area', 0):.3f} vol={vol_s} closed={obj.get('closed')}"
        )
        if issues:
            lines.append("         " + ", ".join(issues))
        nisl = len(uv.get("islands") or [])
        if nisl:
            lines.append(f"         uv_islands={nisl}")

    # Palette
    bad_pal = [
        p
        for p in analysis.get("palette_checks") or []
        if p.get("straddles_swatches")
        or p.get("in_pad_or_gap")
        or not p.get("stays_inside_margin")
    ]
    lines.append(f"palette islands: {len(analysis.get('palette_checks') or [])} checked, {len(bad_pal)} concern(s)")
    for p in analysis.get("palette_checks") or []:
        prim = p.get("primary") or {}
        status = "OK" if p.get("stays_inside_margin") else "WARN"
        lines.append(
            f"  [{status}] {p.get('object')} island#{p.get('island_index')} "
            f"-> {prim.get('label', '?')} row_color={prim.get('row_color')} "
            f"straddle={p.get('straddles_swatches')} pad={p.get('in_pad_or_gap')} "
            f"margin_ok={p.get('stays_inside_margin')}"
        )
        sc = p.get("sampled_color")
        if sc:
            avg = sc["average_rgb"]
            lines.append(f"         avgRGB=({avg[0]:.1f},{avg[1]:.1f},{avg[2]:.1f})")

    # Shape / spec
    shape = analysis.get("shape_metrics") or {}
    ratios = shape.get("ratios") or {}
    if ratios:
        lines.append(
            f"shape: length={ratios.get('length', 0):.3f} wingspan={ratios.get('wingspan', 0):.3f} "
            f"wingspan/length={ratios.get('wingspan/length', 0):.3f}"
        )
    for name, part in (shape.get("parts") or {}).items():
        if name.startswith("wing") and part.get("sweep_deg") is not None:
            lines.append(f"  {name} sweep_deg={part['sweep_deg']:.1f}")

    spec_results = analysis.get("spec_results") or []
    if spec_results:
        passed = sum(1 for r in spec_results if r.get("pass"))
        lines.append(f"spec checks: {passed}/{len(spec_results)} passed")
        for r in spec_results:
            mark = "PASS" if r.get("pass") else "FAIL"
            lines.append(
                f"  [{mark}] {r.get('check')} value={r.get('value')} expected={r.get('expected')} "
                f"{r.get('reason', '')}"
            )
    for e in errors:
        lines.append(f"ERROR id={e.get('id')}: {e.get('error')}")
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=51337)
    ap.add_argument("--objects", type=int, nargs="*", help="Object ids (default: all)")
    ap.add_argument("--palette-config", default="/workspace/colorpoly/config_small.json")
    ap.add_argument("--palette-image", default="/workspace/colorpoly/colorpoly_generated.png")
    ap.add_argument("--margin-px", type=float, default=1.0)
    ap.add_argument("--spec", help="Path to expected-metrics JSON")
    ap.add_argument("--main-part", default="fuselage")
    ap.add_argument("--dump-wings", action="store_true", help="dump_mesh wing parts for sweep angle")
    ap.add_argument("--json-out", help="Write full analysis JSON")
    ap.add_argument("--text-out", help="Write human-readable summary")
    ap.add_argument("--ngon-max", type=int, default=4)
    ap.add_argument("--epsilon", type=float, default=1e-5)
    args = ap.parse_args()

    report = fetch_mesh_report(
        args.host,
        args.port,
        objects=args.objects or None,
        ngon_max=args.ngon_max,
        epsilon=args.epsilon,
    )
    if not report.get("ok"):
        print(json.dumps(report, indent=2))
        sys.exit(1)

    dump_meshes: dict[str, list[list[float]]] = {}
    if args.dump_wings:
        for obj in report.get("objects") or []:
            name = obj.get("name") or ""
            if name.startswith("wing"):
                dump_meshes[name] = fetch_dump_vertices(args.host, args.port, obj["id"])

    spec = None
    if args.spec:
        spec = json.loads(Path(args.spec).read_text())

    analysis = analyze(
        report,
        palette_config=args.palette_config,
        palette_image=args.palette_image,
        margin_px=args.margin_px,
        spec=spec,
        dump_meshes=dump_meshes or None,
        main_part=args.main_part,
    )
    text = summarize(analysis)
    print(text)
    if args.text_out:
        Path(args.text_out).write_text(text)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(analysis, indent=2))


if __name__ == "__main__":
    main()
