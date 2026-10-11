"""Executable little-endian parameter contract; assertion sidecars are never inputs."""
import argparse
import json
from pathlib import Path
import struct
import time

ROOT = Path(__file__).resolve().parents[1]
HEADER = struct.Struct("<8sIIQQQQ40sIIII")
BLOCK = struct.Struct("<4sIQQII")
RECORD = struct.Struct("<QIBBBBII")
MAX_BLOCK = 8 * 1024 * 1024
FIELD_NAMES = [
    "pitchIncrement_0d00", "tvfQDestination_1100", "pitchDestination_1200", "tvfFDestination_1300", "ampModDestination_1400", "ampDestination_1500",
    "tvfQRamp_1600", "pitchRamp_1700", "tvfFRamp_1800", "ampModRamp_1900", "ampRamp_1a00",
    "pitchCurrent_1b00", "tvfFCurrent_1c00", "ampModCurrent_1d00", "ampCurrent_1e00", "tvfQCurrent_2100", "tvfFCoefficient_2200", "combinedAmp_2300",
    "pitchStep_2400", "tvfFStep_2500", "ampStep_2600", "runtimeCache.ampCurve2EntryPending",
]
STAGE_MASKS = {1: sum(1 << i for i in [0, 11, 12, 14, 16]), 2: 1 << 12, 3: (1 << 0) | (1 << 16), 4: ((1 << 22) - 1) & ~sum(1 << i for i in range(6, 10))}


def segment_path(path, index):
    return path if index == 0 else path.with_name(f"{path.stem}.{index:03d}{path.suffix}")


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Truncated header/block/event or missing END")
    return data


def validate_event(event, payload):
    frame, sequence, kind, stage, target, voice, mask, size = event
    if size != len(payload):
        raise ValueError("Payload length mismatch")
    if kind in [6, 7]:
        if target != 1 or not 0 <= voice < 64 or stage not in STAGE_MASKS:
            raise ValueError("Illegal parameter consumption position")
        if kind == 7:
            if stage != 4 or mask or size != 1 or payload[0] > 4:
                raise ValueError("Illegal terminal candidate")
        else:
            if not mask or mask & ~STAGE_MASKS[stage] or size != mask.bit_count() * 4:
                raise ValueError("Illegal field mask/width/stage")
            values = iter(struct.unpack(f"<{mask.bit_count()}I", payload))
            for index in range(22):
                if mask & (1 << index):
                    value = next(values)
                    width = 1 if index == 21 else 20 if index >= 15 else 18
                    if value >= 1 << width or 6 <= index <= 10 and value & 0x20000:
                        raise ValueError("Field width or local hold violation")
        return
    if stage or voice != 255 or mask:
        raise ValueError("Unexpected boundary/host fields")
    if kind in [1, 5, 8]:
        if target or size:
            raise ValueError("Unexpected boundary payload")
    elif kind == 2:
        if target not in [1, 2] or size != 3:
            raise ValueError("Invalid host byte write")
    elif kind == 3:
        if target not in [0, 1, 2] or size != 2 or target == 0 and payload != b"\x8f\xfe":
            raise ValueError("Invalid side-effect read/IRQ query")
    elif kind == 4:
        if target or size != 1:
            raise ValueError("Invalid return gate")
    else:
        raise ValueError("Unknown kind; audio state/PCM cannot be parameter payloads")


def events(path, commit):
    """Yield validated executable records from complete logical blocks and segments."""
    path = Path(path)
    frame = sequence = block_index = segment = records = 0
    end = reset = False
    identity = None
    while not end:
        with segment_path(path, segment).open("rb") as stream:
            h = HEADER.unpack(read_exact(stream, HEADER.size))
            if h[:3] != (b"SC88PAR1", 1, 32000) or h[7] != commit.encode("ascii") or h[8:10] != (1, 1) or h[10:] != (segment, block_index):
                raise ValueError("Invalid parameter header/identity/segment")
            if not h[3] or not h[4] or h[5] > h[4] or h[6] != h[3] + h[4] or h[6] >= 1 << 64:
                raise ValueError("Invalid reset/boot/tail/end duration")
            if identity is not None and h[:10] != identity:
                raise ValueError("Segment identity/duration discontinuity")
            identity = h[:10]
            while True:
                block_header = stream.read(BLOCK.size)
                if not block_header:
                    break
                if len(block_header) != BLOCK.size:
                    raise ValueError("Truncated logical block")
                magic, index, first, last, size, count = BLOCK.unpack(block_header)
                if sequence:
                    raise ValueError("Logical block split inside an audio frame")
                if magic != b"PBL1" or index != block_index or first != frame or not first <= last <= h[6] or not 0 < size <= MAX_BLOCK or not 0 < count <= size // RECORD.size:
                    raise ValueError("Logical block order/range/length mismatch")
                data = read_exact(stream, size)
                offset = 0
                seen = set()
                for record_index in range(count):
                    if offset + RECORD.size > size:
                        raise ValueError("Truncated event header")
                    e = RECORD.unpack_from(data, offset)
                    offset += RECORD.size
                    payload = data[offset:offset + e[7]]
                    offset += e[7]
                    validate_event(e, payload)
                    if e[:2] != (frame, sequence) or frame > last or record_index == count - 1 and frame != last:
                        raise ValueError("Frame/sequence/block endpoint mismatch")
                    if not reset and e[2] != 1 or frame == h[6] and e[2] != 8:
                        raise ValueError("Missing RESET or exact END")
                    if e[2] == 1:
                        if reset or records:
                            raise ValueError("Duplicate RESET")
                        reset = True
                    if e[2] in [6, 7]:
                        key = (frame, e[3], e[5], e[2])
                        if key in seen:
                            raise ValueError("Duplicate control service event")
                        seen.add(key)
                    yield e, payload
                    records += 1
                    sequence += 1
                    if e[2] == 5:
                        frame += 1
                        sequence = 0
                        seen.clear()
                    if e[2] == 8:
                        if frame != h[6] or record_index != count - 1:
                            raise ValueError("Early END/trailing records")
                        end = True
                if offset != size:
                    raise ValueError("Logical block record count mismatch")
                block_index += 1
                if end:
                    if stream.read(1) or segment_path(path, segment + 1).exists():
                        raise ValueError("Trailing block/segment after END")
                    break
        segment += 1


def inspect(path, commit):
    started = time.perf_counter()
    frame_bytes = window_bytes = peak_frame = peak_16 = record_count = 0
    completed = native_bytes = 0
    with Path(path).open("rb") as stream:
        header = HEADER.unpack(read_exact(stream, HEADER.size))
    for event, payload in events(path, commit):
        size = RECORD.size + len(payload)
        frame_bytes += size
        if event[0] >= header[3]:
            native_bytes += size
        record_count += 1
        if event[2] == 5:
            peak_frame = max(peak_frame, frame_bytes)
            window_bytes += frame_bytes
            completed += 1
            if completed % 16 == 0:
                peak_16 = max(peak_16, window_bytes)
                window_bytes = 0
            frame_bytes = 0
    segments = []
    index = 0
    while segment_path(Path(path), index).exists():
        file = segment_path(Path(path), index)
        segments.append({"file": file.name, "bytes": file.stat().st_size})
        index += 1
    return {"success": True, "format_version": 1, "segments": segments, "file_bytes": sum(s["bytes"] for s in segments), "records": record_count, "frames": completed,
            "native_event_bytes": native_bytes, "native_average_event_bytes_per_second": native_bytes * 32000 / header[4], "peak_frame_event_bytes": peak_frame,
            "peak_aligned_16_frame_event_bytes": max(peak_16, window_bytes), "python_validation_seconds_x64": time.perf_counter() - started, "ARMv7": "UNVERIFIED", "USB": "UNVERIFIED"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--commit", default="9af8bb05bcef2994b5dbb60c5c028e978a72aecb")
    args = parser.parse_args()
    print(json.dumps(inspect(args.path, args.commit), ensure_ascii=False))


if __name__ == "__main__":
    main()
