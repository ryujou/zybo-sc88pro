"""Phase 0 cumulative gates. Private audio and ROM data stay under build/private."""
import argparse
import array
import csv
import json
import math
import re
import struct
import subprocess
import sys
import wave
import zipfile
from pathlib import Path

from rom_verify import identify, load_targets, resolve_source, scan, swap_pairs

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/phase-00"
UPSTREAM = ROOT / "external/gearmulator"
ROM_PATH = ""
CONTRACT = json.loads((ROOT / "reference/phase0-contract.json").read_text())
LOCK = json.loads((ROOT / "reference/gearmulator-lock.json").read_text())


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run(command, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as stream:
        subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)


def gate_a():
    run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/check_environment.ps1")], OUT / "logs/environment.log")
    environment = json.loads((OUT / "environment.json").read_text(encoding="utf-8-sig"))
    assert environment["success"], "Environment audit failed"
    lock = json.loads((ROOT / "reference/gearmulator-lock.json").read_text())
    commit = subprocess.check_output(["git", "-C", str(UPSTREAM), "rev-parse", "HEAD"], text=True).strip()
    assert commit == lock["commit"], "Upstream commit differs from lock"
    assert not subprocess.check_output(["git", "-C", str(UPSTREAM), "status", "--porcelain"], text=True).strip(), "Upstream worktree is modified"
    registry = (UPSTREAM / lock["registry"]).read_text()
    contract = json.loads((ROOT / "reference/phase0-contract.json").read_text())
    for rom in contract["roms"]:
        slot = "Control" if rom["role"] == "control" else "Wave"
        pattern = rf'\{{romDevices\(RomDevice::Sc88Pro[^}}]*RomSlot::{slot},\s*{rom["slot"]},\s*0x{rom["size"]:x},\s*baseLib::MD5\("{rom["md5"]}"\)'
        assert re.search(pattern, registry), f"ROM target not in upstream Registry: {rom['role']}"
    for source in ["doc/88emu_readme.md", "LICENSE.md", "source/ronaldo/88emu/88lib/boards/sc88pro.cpp", "source/ronaldo/custom_chips/xp/xp_voice.cpp", "source/ronaldo/custom_chips/lsp/lsp_interpreter.h"]:
        assert (UPSTREAM / source).is_file(), f"Missing reference: {source}"
    assert contract["sample_rate"] == 32000 and len(contract["cases"]) == 11
    return ["tools_executable", "fixed_pristine_commit", "rom_registry_contract", "native_capture_and_case_contract", "upstream_license_available"]


def vlq(value):
    encoded = [value & 127]
    while value >> 7:
        value >>= 7
        encoded.insert(0, (value & 127) | 128)
    return bytes(encoded)


def case_input(case):
    fixtures = OUT / "cases/inputs"
    fixtures.mkdir(parents=True, exist_ok=True)
    if case.get("smf"):
        track = bytearray(b"\x00\xff\x51\x03\x07\xa1\x20")
        previous_tick = 0
        for frame, port, data in case["events"]:
            assert port == 0
            tick, remainder = divmod(frame * 960, CONTRACT["sample_rate"])
            assert remainder == 0, "SMF fixture event is not an exact native frame"
            track += vlq(tick - previous_tick) + bytes(data)
            previous_tick = tick
        track += b"\x00\xff\x2f\x00"
        path = fixtures / f"{case['id']}.mid"
        path.write_bytes(b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(track)) + track)
    else:
        path = fixtures / f"{case['id']}.events"
        path.write_text("".join(f"{frame} {port} " + " ".join(f"{byte:02x}" for byte in data) + "\n" for frame, port, data in case["events"]), encoding="ascii")
    return path


def pcm_values(path, expected_frames):
    data = path.read_bytes()
    if len(data) != expected_frames * 8 or not data:
        raise ValueError(f"Empty/truncated PCM: {path}; bytes={len(data)}, expected={expected_frames * 8}")
    values = array.array("i")
    values.frombytes(data)
    if sys.byteorder != "little":
        values.byteswap()
    if min(values) < -8388608 or max(values) > 8388607:
        raise ValueError("PCM exceeds signed 24-bit range")
    return data, values


def compare_pcm(reference, actual, expected_frames):
    reference_bytes, expected = pcm_values(reference, expected_frames)
    actual_bytes, observed = pcm_values(actual, expected_frames)
    if reference_bytes != actual_bytes:
        for index, (left, right) in enumerate(zip(expected, observed)):
            if left != right:
                raise ValueError(f"First PCM difference: frame={index // 2}, channel={index % 2}, reference={left} (0x{left & 0xffffffff:08x}), actual={right} (0x{right & 0xffffffff:08x})")
    return {"frames":expected_frames, "samples":expected_frames * 2, "max_absolute_error":0, "rms_error":0, "first_difference":None}


def render_case(case, repetition):
    destination = OUT / "cases" / case["id"] / repetition
    runner = ROOT / "build/reference/Release/sc88_reference_runner.exe"
    input_file = case_input(case)
    run([str(runner), str(ROOT / "private/roms"), str(input_file), str(destination), str(CONTRACT["boot_frames"]), str(CONTRACT["case_frames"]), LOCK["commit"]], OUT / "logs" / f"{case['id']}-{repetition}.log")
    log = (OUT / "logs" / f"{case['id']}-{repetition}.log").read_text()
    assert "SC88_REFERENCE_COMPLETE" in log, "Runner completion marker absent"
    runner_metadata = json.loads((destination / "runner.json").read_text())
    assert runner_metadata["case_frames"] == CONTRACT["case_frames"]
    assert runner_metadata["events"] == len(case["events"])
    assert runner_metadata["midi_backlog"] == 0
    assert runner_metadata["sample_rate"] == CONTRACT["sample_rate"]
    boot_data, _ = pcm_values(destination / "boot.pcm", CONTRACT["boot_frames"])
    raw, values = pcm_values(destination / "native.pcm", CONTRACT["case_frames"])
    nonzero = sum(value != 0 for value in values)
    peak = max(abs(value) for value in values)
    dynamic_samples = sum(value != 32 for value in values)
    if case["expect"] == "constant_dc":
        assert all(value == case["dc"] for value in values), "No-MIDI PCM differs from the documented fixed DSP offset"
        with (destination / "xp-end-state.csv").open() as snapshot:
            slots = {int(row["slot"]):row for row in csv.DictReader(snapshot)}
        for slot in [121,135,237,252]:
            assert int(slots[slot]["cram"], 16) == 32
            assert int(slots[slot]["pram"], 16) & 63 in [31,47], "Missing firmware immediate-add instruction"
    else:
        assert dynamic_samples > 0, f"No digital signal beyond the fixed DSP offset in {case['id']}"
    # Lossless 32-bit storage to 24-bit PCM container; no scaling or quantization.
    packed = bytearray(len(values) * 3)
    packed[0::3], packed[1::3], packed[2::3] = raw[0::4], raw[1::4], raw[2::4]
    with wave.open(str(destination / "native.wav"), "wb") as wav:
        wav.setparams((2, 3, CONTRACT["sample_rate"], 0, "NONE", "not compressed"))
        wav.writeframes(packed)
    with wave.open(str(destination / "native.wav"), "rb") as wav:
        assert wav.getframerate() == 32000 and wav.getnframes() == CONTRACT["case_frames"]
        assert wav.readframes(wav.getnframes()) == packed
    metadata = {
        "case":case["id"], "upstream":LOCK, "contract_version":CONTRACT["version"],
        "roms":json.loads((OUT / "roms.json").read_text())["roms"],
        "capture":CONTRACT["capture_format"], "frame_zero":CONTRACT["frame_zero"],
        "events":case["events"], "gain":1, "analog_model":False, "host_resampling":False,
        "limiter":False, "runner":runner_metadata,
        "nonzero_samples":nonzero, "peak":peak,
        "dynamic_samples":dynamic_samples,
        "first_signal_frame":next((i // 2 for i, value in enumerate(values) if value != 32), None),
        "rms":math.sqrt(sum(value * value for value in values) / len(values)),
        "boot_bytes":len(boot_data)
    }
    write_json(destination / "metadata.json", metadata)
    print(f"  {case['id']}/{repetition}: frames={CONTRACT['case_frames']}, dynamic={dynamic_samples}, peak={peak}", flush=True)
    return destination


def gate_b():
    source = resolve_source(ROM_PATH)
    result = scan(source, load_targets(), ROOT / "private/roms")
    write_json(OUT / "roms.json", result)
    if ROM_PATH and Path(ROM_PATH).is_file() and zipfile.is_zipfile(ROM_PATH):
        write_json(OUT / "source-archive.json", scan(Path(ROM_PATH), load_targets()))
    run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_reference.ps1")], OUT / "logs/build_reference.log")
    for case in CONTRACT["cases"][:2]:
        render_case(case, "first")
    return ["control_waveA_waveB_waveC_verified", "reference_build", "factory_reset_native_boot", "post_boot_constant_dc_and_firmware_immediate", "nonzero_single_note", "raw_int32_and_lossless_wav24"]


def must_reject(action, name):
    try:
        action()
    except (ValueError, FileNotFoundError) as error:
        return {"name":name, "rejected":True, "reason":str(error)}
    raise AssertionError(f"Negative test was accepted: {name}")


def negative_tests():
    targets = load_targets()
    negative = OUT / "cases/negative"
    negative.mkdir(parents=True, exist_ok=True)
    control = (ROOT / "private/roms/sc88pro_control.bin").read_bytes()
    wave_a = (ROOT / "private/roms/sc88pro_wave0.bin").read_bytes()
    records = []
    for name, data in [("wrong_size", control[:-1]), ("changed_control_byte", bytes([control[0] ^ 1]) + control[1:]), ("unsupported_wave_byte_order", swap_pairs(wave_a))]:
        assert identify(data, targets) is None, f"ROM negative accepted: {name}"
        records.append({"name":name, "rejected":True})
    swapped_match = identify(swap_pairs(control), targets)
    assert swapped_match and swapped_match[0]["role"] == "control" and swapped_match[1] == "word_swapped"
    records.append({"name":"recognized_control_word_swap", "accepted":True})
    renamed_zip = negative / "renamed.zip"
    with zipfile.ZipFile(renamed_zip, "w") as archive:
        for i, target in enumerate(targets):
            archive.writestr(f"arbitrary_{i}.dat", (ROOT / "private/roms" / target["name"]).read_bytes())
    assert scan(renamed_zip, targets)["success"]
    records.append({"name":"arbitrary_filenames", "accepted":True})
    wrong_zip = negative / "wrong_model.zip"
    with zipfile.ZipFile(wrong_zip, "w") as archive:
        # Same-size SC-8850 program from the user's archive, named as SC-88Pro control.
        source = json.loads((OUT / "source-archive.json").read_text())["source"] if (OUT / "source-archive.json").exists() else None
        if source and Path(source).is_file():
            with zipfile.ZipFile(source) as original:
                other = original.read("sc8850/8850.bin")
        else:
            other = bytes(len(control))
        archive.writestr("sc88pro_control.bin", other)
        for target in targets:
            if target["role"] != "control":
                archive.writestr(target["name"], (ROOT / "private/roms" / target["name"]).read_bytes())
    records.append(must_reject(lambda:scan(wrong_zip, targets), "same_size_wrong_model_with_canonical_name"))
    records.append(must_reject(lambda:scan(negative / "missing", targets), "missing_rom_path"))
    empty = negative / "empty"
    empty.mkdir(exist_ok=True)
    records.append(must_reject(lambda:scan(empty, targets), "missing_rom_roles"))
    reference = OUT / "cases/piano/first/native.pcm"
    changed = bytearray(reference.read_bytes())
    changed[0] ^= 1
    changed_path = negative / "changed.pcm"
    changed_path.write_bytes(changed)
    empty_pcm = negative / "empty.pcm"
    empty_pcm.write_bytes(b"")
    truncated = negative / "truncated.pcm"
    truncated.write_bytes(changed[:-8])
    records.append(must_reject(lambda:compare_pcm(reference, changed_path, CONTRACT["case_frames"]), "single_sample_bit_change"))
    records.append(must_reject(lambda:compare_pcm(reference, empty_pcm, CONTRACT["case_frames"]), "empty_pcm"))
    records.append(must_reject(lambda:compare_pcm(reference, truncated, CONTRACT["case_frames"]), "missing_final_frame"))
    write_json(OUT / "negative-tests.json", {"success":True, "tests":records})
    return records


def gate_c():
    comparisons = []
    for index, case in enumerate(CONTRACT["cases"]):
        first = OUT / "cases" / case["id"] / "first" if index < 2 else render_case(case, "first")
        repeat = render_case(case, "repeat")
        result = compare_pcm(first / "native.pcm", repeat / "native.pcm", CONTRACT["case_frames"])
        compare_pcm(first / "boot.pcm", repeat / "boot.pcm", CONTRACT["boot_frames"])
        assert json.loads((first / "runner.json").read_text()) == json.loads((repeat / "runner.json").read_text()), f"Nondeterministic state: {case['id']}"
        assert (first / "xp-end-state.csv").read_bytes() == (repeat / "xp-end-state.csv").read_bytes(), f"Nondeterministic XP snapshot: {case['id']}"
        comparisons.append({"case":case["id"], "native":result, "boot_exact":True, "runner_state_exact":True})
        write_json(OUT / "repeatability.json", {"success":len(comparisons) == len(CONTRACT["cases"]), "comparisons":comparisons})
    for left, right in [("velocity_low", "velocity_high"), ("effects_dry", "effects_wet")]:
        assert (OUT / "cases" / left / "first/native.pcm").read_bytes() != (OUT / "cases" / right / "first/native.pcm").read_bytes(), f"Parameter contrast ineffective: {left}/{right}"
    low = json.loads((OUT / "cases/velocity_low/first/metadata.json").read_text())
    high = json.loads((OUT / "cases/velocity_high/first/metadata.json").read_text())
    assert high["peak"] > low["peak"], "Velocity high/low amplitude ordering failed"
    short_midi = next(case for case in CONTRACT["cases"] if case["id"] == "short_midi")
    direct = render_case({**short_midi, "id":"short_midi_direct", "smf":False}, "first")
    smf_result = compare_pcm(OUT / "cases/short_midi/first/native.pcm", direct / "native.pcm", CONTRACT["case_frames"])
    pitch = next(case for case in CONTRACT["cases"] if case["id"] == "pitch")
    neutral = render_case({**pitch, "id":"pitch_neutral", "events":[event for event in pitch["events"] if event[2][0] != 224]}, "first")
    assert (OUT / "cases/pitch/first/native.pcm").read_bytes() != (neutral / "native.pcm").read_bytes(), "Pitch Bend events had no effect"
    write_json(OUT / "functional-checks.json", {"success":True, "velocity_peak_order":True, "effects_change_output":True, "pitch_bend_changes_same_patch":True, "smf_vs_native_event_schedule":smf_result})
    negative_tests()
    ignored = (ROOT / ".gitignore").read_text().splitlines()
    assert "/build/" in ignored and "/private/" in ignored and "/external/gearmulator/" in ignored
    return ["11_native_cases", "11_exact_pcm_boot_state_repeats", "velocity_pitch_effect_contrasts", "smf_matches_direct_native_event_schedule", "rom_and_pcm_negative_tests", "private_data_excluded"]


def gate_d():
    assert json.loads((OUT / "repeatability.json").read_text())["success"]
    assert json.loads((OUT / "functional-checks.json").read_text())["success"]
    assert json.loads((OUT / "negative-tests.json").read_text())["success"]
    notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    assert LOCK["commit"] in notice and "GPL-3.0" in notice
    phase_doc = (ROOT / "docs/phases/phase-00.md").read_text(encoding="utf-8")
    for expected in ["32", "24", "256,000", "run_gate.ps1", "NOT_TESTED_ON_HARDWARE"]:
        assert expected in phase_doc, f"Missing documented reference contract: {expected}"
    for doc in (ROOT / "docs").rglob("*.md"):
        for link in re.findall(r'\[[^\]]+\]\(([^)]+)\)', doc.read_text(encoding="utf-8")):
            if not link.startswith(("https:", "http:", "#")):
                assert (doc.parent / link.split("#")[0]).exists(), f"Broken document link: {doc.name} -> {link}"
    public_dirs = [ROOT / name for name in ["docs", "host", "reference", "scripts", "verification"]]
    for directory in public_dirs:
        if directory.exists():
            for path in directory.rglob("*"):
                assert path.suffix.lower() not in [".bin", ".pcm", ".wav", ".mid", ".zip"], f"Private payload outside build/private: {path}"
    assert not subprocess.check_output(["git", "-C", str(UPSTREAM), "status", "--porcelain"], text=True).strip(), "Reference source was modified"
    assert (ROOT / "LICENSE.md").read_text(encoding="utf-8").strip() == (UPSTREAM / "LICENSE.md").read_text(encoding="utf-8").strip(), "GPL license copy differs"
    subprocess.run(["git", "check-ignore", "private/roms/sc88pro_control.bin", "build/reference/Release/sc88_reference_runner.exe", "external/gearmulator/LICENSE.md"], cwd=ROOT, check=True, capture_output=True)
    metrics = []
    for case in CONTRACT["cases"]:
        metadata = json.loads((OUT / "cases" / case["id"] / "first/metadata.json").read_text())
        metrics.append({key:metadata[key] for key in ["case", "peak", "dynamic_samples", "first_signal_frame"]})
    summary = {"schema_version":1, "phase":0, "status":"通过", "scope":"software", "commit":LOCK["commit"], "sample_rate":32000, "valid_bits":24, "raw_container_bits":32, "cases":metrics, "repeat_pcm_frames":CONTRACT["case_frames"] * len(CONTRACT["cases"]), "repeat_boot_frames":CONTRACT["boot_frames"] * len(CONTRACT["cases"]), "max_absolute_error":0, "rms_error":0, "silence_dc":[32,32], "hardware_verified":False, "hardware_status":"NOT_TESTED_ON_HARDWARE", "hls_resources":"N/A", "fpga_resources":"N/A", "golden_reference_only":True}
    write_json(OUT / "summary.json", summary)
    # Public summary contains only counts, numeric metrics and source identity, never ROM/PCM bytes.
    write_json(ROOT / "verification/phase-00/summary.json", summary)
    return ["evidence_complete", "reference_source_pristine", "document_links_and_capture_contract", "license_notices", "no_private_payload_in_public_dirs"]


def main():
    global ROM_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, default=0)
    parser.add_argument("--step", choices=list("ABCD"), default="D")
    parser.add_argument("--rom-path", default="")
    args = parser.parse_args()
    ROM_PATH = args.rom_path
    if args.phase != 0:
        parser.error("Only Phase 0 is implemented; later phases cannot pass.")
    OUT.mkdir(parents=True, exist_ok=True)
    for summary_path in [OUT / "summary.json", ROOT / "verification/phase-00/summary.json"]:
        if summary_path.exists():
            write_json(summary_path, {"schema_version":1, "phase":0, "status":"未开始", "scope":"software", "hardware_verified":False})
    checks = []
    gates = {"A": gate_a, "B": gate_b, "C": gate_c, "D": gate_d}
    for step in "ABCD"[:"ABCD".index(args.step) + 1]:
        # A rerun invalidates all downstream results, including old passes.
        for downstream in "ABCD"["ABCD".index(step):]:
            write_json(OUT / f"gate-{downstream}.json", {"schema_version":1, "phase":0, "step":downstream, "status":"未开始", "scope":"software", "checks":[], "failed_checks":[], "hardware_verified":False})
        try:
            if step not in gates:
                raise RuntimeError(f"Gate {step} has not been implemented")
            checks.extend(gates[step]())
        except Exception as error:
            write_json(OUT / f"gate-{step}.json", {"schema_version":1, "phase":0, "step":step, "status":"未通过", "scope":"software", "checks":checks, "failed_checks":[str(error)], "hardware_verified":False})
            raise
        write_json(OUT / f"gate-{step}.json", {"schema_version":1, "phase":0, "step":step, "status":"通过", "scope":"software", "checks":checks, "failed_checks":[], "hardware_verified":False})
        print(f"Phase 0 Gate {step}: passed ({len(checks)} checks)", flush=True)


if __name__ == "__main__":
    main()
