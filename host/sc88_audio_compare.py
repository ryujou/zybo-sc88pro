"""Exact native PCM comparison, with Trace context at the first integer difference."""
import argparse
from collections import deque
import json
import math
import struct
import zlib
from pathlib import Path

from phase0 import pcm_values, write_json

RECORD = struct.Struct("<QIBBHII")


def trace_context(path, target):
    events = deque(maxlen=32)
    checkpoint = None
    with Path(path).open("rb") as stream:
        header = stream.read(80)
        if len(header) != 80 or header[:8] != b"SC88TRC1" or struct.unpack_from("<II",header,8) != (1,32000) or zlib.crc32(header[:76]) != struct.unpack_from("<I", header, 76)[0]:
            raise ValueError("Invalid Trace header")
        while raw := stream.read(RECORD.size):
            if len(raw) != RECORD.size:
                raise ValueError("Truncated Trace record")
            frame, sequence, kind, chip, address, value, crc = RECORD.unpack(raw)
            payload = stream.read(value) if kind in [7, 8] else b""
            if kind in [7, 8] and len(payload) != value:
                raise ValueError("Truncated Trace checkpoint")
            if zlib.crc32(payload, zlib.crc32(raw[:20])) != crc:
                raise ValueError("Trace CRC mismatch")
            if frame > target:
                break
            if kind in [7, 8]:
                checkpoint = {"frame":frame, "words":len(payload) // 8, "interpretation":"last observed checkpoint before difference, not an inferred per-frame state"}
            elif kind in [2, 3, 4, 5]:
                events.append({"frame":frame, "sequence":sequence, "kind":kind, "chip":chip, "address":f"0x{address:04x}", "value":value, "voice_candidate":(address & 255) // 4 if chip == 1 and address < 0x2b00 and address >> 8 not in [8,9,10,11] else None})
    return {"recent_events":list(events), "last_state_checkpoint":checkpoint, "voice_attribution":"candidates from register bank; PCM alone does not identify a causal Voice"}


def compare(reference, actual, frames, trace=None, frame_offset=0):
    expected_bytes, expected = pcm_values(Path(reference), frames)
    actual_bytes, observed = pcm_values(Path(actual), frames)
    result = {"success":True, "frames":frames, "samples":frames * 2, "max_absolute_error":0, "peak_error":0, "rms_error":0, "first_difference":None}
    if expected_bytes == actual_bytes:
        return result
    square_sum = 0
    for index, (left, right) in enumerate(zip(expected, observed)):
        difference = right - left
        square_sum += difference * difference
        result["max_absolute_error"] = max(result["max_absolute_error"], abs(difference))
        if difference and result["first_difference"] is None:
            first = {"frame":index // 2, "absolute_trace_frame":index // 2 + frame_offset, "channel":"L" if index % 2 == 0 else "R", "reference":left, "actual":right, "difference":difference, "reference_hex":f"0x{left & 0xffffffff:08x}", "actual_hex":f"0x{right & 0xffffffff:08x}"}
            if trace:
                first["trace_context"] = trace_context(trace, first["absolute_trace_frame"])
            result["first_difference"] = first
    result["success"] = False
    result["peak_error"] = result["max_absolute_error"]
    result["rms_error"] = math.sqrt(square_sum / len(expected))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--frame-offset", type=int, default=0)
    args = parser.parse_args()
    result = compare(args.reference, args.actual, args.frames, args.trace, args.frame_offset)
    write_json(args.report, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
