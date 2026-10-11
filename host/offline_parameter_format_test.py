"""Meaningful malformed-container and multi-segment parameter contract checks."""
import json
from pathlib import Path
import struct

import offline_parameter_format as f

COMMIT = "9af8bb05bcef2994b5dbb60c5c028e978a72aecb"
OUT = f.ROOT / "build/verification/offline-player/phase-01/format-cases"


def record(frame, sequence, kind, stage=0, target=0, voice=255, mask=0, payload=b""):
    return f.RECORD.pack(frame, sequence, kind, stage, target, voice, mask, len(payload)) + payload


def header(segment=0, block=0):
    return f.HEADER.pack(b"SC88PAR1", 1, 32000, 1, 1, 0, 2, COMMIT.encode(), 1, 1, segment, block)


def block(records, index=0, first=0, last=2):
    payload = b"".join(records)
    return f.BLOCK.pack(b"PBL1", index, first, last, len(payload), len(records)) + payload


def run():
    OUT.mkdir(parents=True, exist_ok=True)
    base = [record(0, 0, 1), record(0, 1, 6, 3, 1, 0, 1, struct.pack("<I", 4)), record(0, 2, 5), record(1, 0, 5), record(2, 0, 8)]
    results = []
    normal = OUT / "normal.scp"
    normal.write_bytes(header() + block(base))
    if len(list(f.events(normal, COMMIT))) != 5:
        raise ValueError("Normal parameter fixture did not decode")
    results.append({"case": "normal_lossless_values", "success": True})
    split = OUT / "split.scp"
    split.write_bytes(header() + block(base[:3], 0, 0, 0))
    f.segment_path(split, 1).write_bytes(header(1, 1) + block(base[3:], 1, 1, 2))
    if list(f.events(split, COMMIT)) != list(f.events(normal, COMMIT)):
        raise ValueError("Segmented parameter values/order differ")
    results.append({"case": "complete_block_segment_continuity", "success": True})
    damaged = {
        "missing_RESET": header() + block(base[1:]),
        "unknown_audio_post_state_kind": header() + block([record(0, 0, 9), *base[1:]]),
        "unknown_mask": header() + block([base[0], record(0, 1, 6, 3, 1, 0, 1 << 31, struct.pack("<I", 4)), *base[2:]]),
        "field_width": header() + block([base[0], record(0, 1, 6, 3, 1, 0, 1, struct.pack("<I", 1 << 18)), *base[2:]]),
        "local_hold_injection": header() + block([base[0], record(0, 1, 6, 4, 1, 0, 1 << 10, struct.pack("<I", 0x20000)), *base[2:]]),
        "wrong_stage": header() + block([base[0], record(0, 1, 6, 2, 1, 0, 1, struct.pack("<I", 4)), *base[2:]]),
        "voice_out_of_range": header() + block([base[0], record(0, 1, 6, 3, 1, 64, 1, struct.pack("<I", 4)), *base[2:]]),
        "duplicate_sequence": header() + block([base[0], record(0, 0, 6, 3, 1, 0, 1, struct.pack("<I", 4)), *base[2:]]),
        "wrong_frame": header() + block([base[0], record(1, 1, 6, 3, 1, 0, 1, struct.pack("<I", 4)), *base[2:]]),
        "missing_END": header() + block(base[:-1], last=1),
        "truncated_block": (header() + block(base))[:-1],
        "trailing_bytes": header() + block(base) + b"x",
        "early_END": header() + block([base[0], record(0, 1, 8)], last=0),
        "duplicate_service_delta": header() + block([base[0], base[1], record(0, 2, 6, 3, 1, 0, 1, struct.pack("<I", 4)), record(0, 3, 5), *base[3:]]),
        "split_inside_frame": header() + block(base[:2], 0, 0, 0) + block(base[2:], 1, 0, 2),
    }
    for name, data in damaged.items():
        path = OUT / f"{name}.scp"
        path.write_bytes(data)
        try:
            list(f.events(path, COMMIT))
        except (ValueError, FileNotFoundError) as error:
            results.append({"case": name, "success": True, "rejected": str(error)})
        else:
            raise ValueError(f"Malformed parameter accepted: {name}")
    missing = OUT / "missing_segment.scp"
    missing.write_bytes(header() + block(base[:3], 0, 0, 0))
    try:
        list(f.events(missing, COMMIT))
    except FileNotFoundError:
        results.append({"case": "missing_segment", "success": True})
    else:
        raise ValueError("Missing segment accepted")
    report = {"success": True, "tests": results, "hashes_or_checksums": False}
    (OUT.parent / "format-tests.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    print(json.dumps(run(), ensure_ascii=False))
