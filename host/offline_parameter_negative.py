"""Reject executable-parameter damage, semantic changes, and invalid comparisons."""
import json
from pathlib import Path
import shutil
import struct
import subprocess

import phase0 as p0
import offline_parameter_format as fmt
from sc88_audio_compare import compare

ROOT = p0.ROOT
OUT = ROOT / "build/verification/offline-player/phase-01"
BIN = ROOT / "build/offline-player/Release/sc88_parameter_replay.exe"


def locations(data):
    offset = fmt.HEADER.size
    while offset < len(data):
        magic, index, first, last, size, count = fmt.BLOCK.unpack_from(data, offset)
        if magic != b"PBL1":
            raise ValueError("Invalid generated mutation source")
        position = offset + fmt.BLOCK.size
        for _ in range(count):
            event = fmt.RECORD.unpack_from(data, position)
            yield {"block": offset, "offset": position, "size": fmt.RECORD.size + event[7], "event": event}
            position += fmt.RECORD.size + event[7]
        if position != offset + fmt.BLOCK.size + size:
            raise ValueError("Mutation source record-count mismatch")
        offset = position


def change_block(data, selected, replacement):
    """Replace complete records and repair only structural lengths/sequences."""
    offset = selected["block"]
    h = list(fmt.BLOCK.unpack_from(data, offset))
    position = offset + fmt.BLOCK.size
    end = position + h[4]
    chunks = []
    while position < end:
        e = fmt.RECORD.unpack_from(data, position)
        size = fmt.RECORD.size + e[7]
        if position == selected["offset"]:
            chunks.extend(replacement)
        else:
            chunks.append(data[position:position + size])
        position += size
    repaired = []
    frame = None
    sequence = 0
    for chunk in chunks:
        e = list(fmt.RECORD.unpack_from(chunk))
        if e[0] != frame:
            frame = e[0]
            sequence = 0
        e[1] = sequence
        sequence += 1
        repaired.append(fmt.RECORD.pack(*e) + chunk[fmt.RECORD.size:])
    payload = b"".join(repaired)
    h[4], h[5] = len(payload), len(repaired)
    return data[:offset] + fmt.BLOCK.pack(*h) + payload + data[end:]


def run():
    case = OUT / "cases/piano"
    source = case / "export/song.scp"
    original = source.read_bytes()
    assertions = case / "export/assertions.bin"
    boot = 256000
    selected = {}
    previous = None
    staged = {}
    for location in locations(original):
        e = location["event"]
        if e[2] == 6 and e[0] > boot + 3200:
            selected.setdefault("delta", location)
            if e[3] == 3 and e[6] & (1 << 16):
                selected.setdefault("coefficient", location)
            if e[3] == 3:
                selected.setdefault("stage", location)
        if e[2] == 2 and e[4] == 1:
            address, value = struct.unpack_from("<HB", original, location["offset"] + 24)
            old = staged.get(address, 0)
            if e[0] > boot and address & 1 and address < 0x2b00 and previous and previous["event"][0] == e[0] and previous["block"] == location["block"]:
                prior_address, prior_value = struct.unpack_from("<HB", original, previous["offset"] + 24)
                if prior_address == address - 1 and prior_value != previous["old"]:
                    selected.setdefault("byte_pair", (previous, location))
            staged[address] = value
            location["old"] = old
            previous = location
        elif e[2] != 2:
            previous = None
        if all(name in selected for name in ["delta", "coefficient", "stage", "byte_pair"]):
            break
    if len(selected) != 4:
        raise ValueError("Piano did not provide meaningful semantic mutation locations")
    destination = OUT / "negative"
    destination.mkdir(parents=True, exist_ok=True)
    tests = []

    def evaluate(name, data, sidecar=assertions, semantic=False):
        path = destination / f"{name}.scp"
        path.write_bytes(data)
        output = destination / name
        command = [str(BIN), str(ROOT / "private/roms"), str(path), str(output), p0.LOCK["commit"], str(sidecar)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
        (destination / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            if semantic and result.stderr.startswith(("Illegal control", "Truncated", "Parameter magic", "Parameter version", "Parameter identity", "Parameter frame/sequence", "Logical block")):
                raise ValueError(f"Semantic mutation failed only container validation: {name}/{result.stderr}")
            tests.append({"name": name, "rejected": True, "reason": result.stderr.strip()})
            return
        differences = {part: compare(case / "reference" / f"{part}.pcm", output / f"{part}.pcm", 256000) for part in ["boot", "native"]}
        if all(report["success"] for report in differences.values()):
            raise ValueError(f"Parameter corruption accepted with unchanged PCM/state: {name}")
        p0.write_json(destination / f"{name}-first-difference.json", differences)
        tests.append({"name": name, "rejected": True, "reason": "exact PCM comparator rejected semantic change"})

    coefficient = selected["coefficient"]
    damaged = bytearray(original)
    e = coefficient["event"]
    value_offset = coefficient["offset"] + 24 + ((e[6] & ((1 << 16) - 1)).bit_count()) * 4
    value = struct.unpack_from("<I", damaged, value_offset)[0]
    struct.pack_into("<I", damaged, value_offset, value ^ 0x40000)
    evaluate("changed_valid_TVF_coefficient", damaged, semantic=True)
    evaluate("dropped_computed_control_delta", change_block(original, selected["delta"], []), semantic=True)
    damaged = bytearray(original)
    damaged[selected["stage"]["offset"] + 13] = 1
    evaluate("wrong_valid_consumption_stage", damaged, semantic=True)
    first, second = selected["byte_pair"]
    start, end = first["offset"], second["offset"] + second["size"]
    combined = original[second["offset"]:end] + original[start:start + first["size"]]
    damaged = bytearray(original)
    damaged[start:end] = combined
    # Preserve original sequence positions so only byte order changes.
    struct.pack_into("<I", damaged, start + 8, first["event"][1])
    struct.pack_into("<I", damaged, start + second["size"] + 8, second["event"][1])
    evaluate("noncommuting_host_byte_order", damaged, semantic=True)
    delta = selected["delta"]
    chunk = original[delta["offset"]:delta["offset"] + delta["size"]]
    evaluate("duplicate_control_service_delta", change_block(original, delta, [chunk, chunk]))
    damaged = bytearray(original)
    struct.pack_into("<Q", damaged, delta["offset"], delta["event"][0] + 1)
    evaluate("wrong_absolute_frame", damaged)
    damaged = bytearray(original)
    struct.pack_into("<I", damaged, coefficient["offset"] + 16, 1 << 31)
    evaluate("unknown_field_mask", damaged)
    damaged = bytearray(original)
    struct.pack_into("<I", damaged, value_offset, 1 << 20)
    evaluate("field_width_overflow", damaged)
    damaged = bytearray(original)
    damaged[delta["offset"] + 14] = 2
    evaluate("wrong_control_target", damaged)
    damaged = bytearray(original)
    damaged[delta["offset"] + 15] = 64
    evaluate("voice_out_of_range", damaged)
    damaged = bytearray(original)
    damaged[delta["offset"] + 12] = 10
    evaluate("forbidden_golden_post_state_kind", damaged)
    first_record = next(locations(original))
    evaluate("missing_RESET", change_block(original, first_record, []))
    last = None
    for location in locations(original):
        last = location
    if last["event"][2] != 8:
        raise ValueError("Source lacks final END")
    evaluate("missing_END", change_block(original, last, []))
    evaluate("truncated_logical_block", original[:-1])
    damaged = bytearray(original)
    struct.pack_into("<I", damaged, 104 + 24, struct.unpack_from("<I", damaged, 104 + 24)[0] + 1)
    evaluate("wrong_logical_block_length", damaged)
    evaluate("trailing_record_bytes", original + b"x")
    damaged_assertions = bytearray(assertions.read_bytes())
    damaged_assertions[8 + 24] ^= 1
    altered = destination / "changed-state-assertion.bin"
    altered.write_bytes(damaged_assertions)
    evaluate("changed_assertion_is_detected_not_injected", original, altered, semantic=True)
    read_assertions = bytearray(assertions.read_bytes())
    position = 8
    while position < len(read_assertions):
        kind = read_assertions[position + 12]
        size = struct.unpack_from("<I", read_assertions, position + 20)[0]
        if kind == 3:
            read_assertions[position + 16] ^= 1
            break
        position += 24 + size
    else:
        raise ValueError("Read-result assertion fixture is absent")
    altered_read = destination / "changed-read-assertion.bin"
    altered_read.write_bytes(read_assertions)
    evaluate("changed_read_result_assertion", original, altered_read, semantic=True)
    split_offset = None
    split_index = None
    for location in locations(original):
        if location["event"][0] == boot and location["offset"] == location["block"] + fmt.BLOCK.size:
            split_offset = location["block"]
            split_index = fmt.BLOCK.unpack_from(original, split_offset)[1]
            break
    if split_offset is None:
        raise ValueError("Missing complete boot/native logical-block boundary")
    split = destination / "segmented.scp"
    split.write_bytes(original[:split_offset])
    continuation = bytearray(original[:104])
    struct.pack_into("<II", continuation, 96, 1, split_index)
    continuation.extend(original[split_offset:])
    fmt.segment_path(split, 1).write_bytes(continuation)
    p0.run([str(BIN), str(ROOT / "private/roms"), str(split), str(destination / "segmented-replay"), p0.LOCK["commit"], str(assertions)], destination / "segmented-replay.log")
    for part in ["boot", "native"]:
        if not compare(case / "reference" / f"{part}.pcm", destination / "segmented-replay" / f"{part}.pcm", 256000)["success"]:
            raise ValueError("Complete-block segmented replay differs")
    tests.append({"name": "positive_segmented_complete_block_replay", "passed": True})
    evaluate("missing_parameter_segment", original[:split_offset])
    damaged_continuation = bytearray(continuation)
    struct.pack_into("<I", damaged_continuation, 96, 2)
    fmt.segment_path(destination / "wrong_segment_header.scp", 1).write_bytes(damaged_continuation)
    evaluate("wrong_segment_header", original[:split_offset])
    wave_directory = destination / "wave-only"
    wave_directory.mkdir(parents=True, exist_ok=True)
    for i in range(3):
        name = f"sc88pro_wave{i}.bin"
        shutil.copyfile(ROOT / "private/roms" / name, wave_directory / name)
    if (wave_directory / "sc88pro_control.bin").exists():
        raise ValueError("Wave-only fixture contains Control ROM")
    p0.run([str(BIN), str(wave_directory), str(source), str(destination / "wave-only-replay"), p0.LOCK["commit"]], destination / "wave-only-replay.log")
    for part in ["boot", "native"]:
        if not compare(case / "reference" / f"{part}.pcm", destination / "wave-only-replay" / f"{part}.pcm", 256000)["success"]:
            raise ValueError("Assertion-free Wave-only replay differs")
    report = json.loads((destination / "wave-only-replay/replay.json").read_text(encoding="utf-8"))
    if report["control_rom_loaded"] or report["state_checkpoints"] or report["control_implementations_executed"]:
        raise ValueError("Wave-only replay depends on control/assertion state")
    tests.append({"name": "Wave_only_no_assertion_file_exact_replay", "passed": True})
    expected = case / "reference/native.pcm"
    changed = bytearray(expected.read_bytes())
    changed[0] ^= 1
    path = destination / "changed-first-sample.pcm"
    path.write_bytes(changed)
    difference = compare(expected, path, 256000, frame_offset=256000)
    p0.write_json(destination / "first-PCM-difference.json", difference)
    if difference["success"] or difference["first_difference"]["frame"] != 0 or difference["first_difference"]["channel"] != "L" or difference["max_absolute_error"] != 1:
        raise ValueError("PCM comparator failed first-difference contract")
    tests.append({"name": "PCM_first_sample_bit_change", "rejected": True})
    for name, data in [("empty_PCM", b""), ("missing_final_PCM_frame", changed[:-8])]:
        path = destination / f"{name}.pcm"
        path.write_bytes(data)
        try:
            compare(expected, path, 256000)
        except ValueError:
            tests.append({"name": name, "rejected": True})
        else:
            raise ValueError(f"Comparator accepted {name}")
    for name, actual, code in [("CLI_equal", expected, 0), ("CLI_changed", destination / "changed-first-sample.pcm", 1)]:
        result = subprocess.run(["py", "-3", "-X", "utf8", str(ROOT / "host/sc88_audio_compare.py"), str(expected), str(actual), "--frames", "256000", "--report", str(destination / f"{name}.json")], capture_output=True, text=True, encoding="utf-8")
        if result.returncode != code:
            raise ValueError(f"Comparator CLI returned {result.returncode}, expected {code}")
        tests.append({"name": name, "passed": True})
    p0.write_json(OUT / "negative-tests.json", {"success": True, "tests": tests})
    return tests


if __name__ == "__main__":
    print(json.dumps(run(), ensure_ascii=False))
