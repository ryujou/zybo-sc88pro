"""Cumulative Phase 1 gates for cold-start, CPU-free XP/LSP Trace replay."""
import argparse
import json
import subprocess
import struct
import zlib
from pathlib import Path

import phase0 as p0
from sc88_audio_compare import compare, RECORD

ROOT = p0.ROOT
OUT = ROOT / "build/verification/phase-01"
CONTRACT = json.loads((ROOT / "reference/phase1-contract.json").read_text())
CASES = p0.CONTRACT["cases"] + CONTRACT["extra_cases"]
BIN = ROOT / "build/trace/Release"
ROM = ROOT / "private/roms"


def gate_a():
    previous = json.loads((p0.OUT / "gate-D.json").read_text())
    assert previous["status"] == "通过" and not previous["failed_checks"], "Phase 0 D must pass first"
    assert subprocess.check_output(["git", "-C", str(p0.UPSTREAM), "rev-parse", "HEAD"], text=True).strip() == p0.LOCK["commit"]
    assert not subprocess.check_output(["git", "-C", str(p0.UPSTREAM), "status", "--porcelain"], text=True).strip()
    sources = {}
    for name in ["88emu/88lib/boards/sc88pro.cpp", "custom_chips/xp/xp_host.cpp", "custom_chips/xp/xp.cpp", "custom_chips/lsp/lsp.h"]:
        path = p0.UPSTREAM / "source/ronaldo" / name
        assert path.is_file()
        sources[name] = path.read_text()
    assert "commitReleasedVoices();" in sources["custom_chips/xp/xp_host.cpp"]
    assert "m_state.interrupt = false;" in sources["custom_chips/xp/xp_host.cpp"]
    assert "returns = {lspOutput.first >> 8, lspOutput.second >> 8}" in sources["88emu/88lib/boards/sc88pro.cpp"]
    assert CONTRACT["record_bytes"] == 24 and CONTRACT["sample_rate"] == 32000
    assert len(p0.CONTRACT["cases"] + CONTRACT["extra_cases"]) == 15
    p0.write_json(OUT / "source-boundary.json", {"commit":p0.LOCK["commit"], "read_side_effects":["voice release commit", "readback latch", "byte read latch", "IRQ acknowledge"], "cpu_state_imported":False, "feedback":"XP -> SDOB -> LSP -> SDIA next frame", "port":"P3DR bit7", "sources":list(sources)})
    return ["phase0_D_entry", "pinned_pristine_sources", "read_IRQ_reset_feedback_boundary", "trace_v1_and_15_cases_fixed"]


def gate_b():
    p0.write_json(OUT / "roms.json", p0.scan(p0.resolve_source(p0.ROM_PATH), p0.load_targets(), ROM))
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_reference.ps1")], OUT / "logs/build_reference.log")
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_trace.ps1")], OUT / "logs/build_trace.log")
    link_map = (ROOT / "build/trace/sc88_trace_replay.map").read_text()
    assert "h8500" not in link_map.lower() and "sc88_board" not in link_map.lower() and "sc88_trace_board" not in link_map.lower(), "Replay links H8/board code"
    replay_source = (ROOT / "host/trace/replay.cpp").read_text()
    assert "sc88pro_control" not in replay_source and "Sc88Pro" not in replay_source
    results = [run_case(case) for case in CASES[:2]]
    p0.write_json(OUT / "comparisons.json", {"success":True, "cases":results})
    return ["ROM_identity", "export_replay_build", "replay_link_map_without_H8_board", "silence_piano_cold_start_exact_PCM_state", "instrumentation_matches_unmodified_reference"]


def run_case(case):
    destination = OUT / "cases" / case["id"]
    # Keep Phase 1 inputs/evidence in its own output tree.
    phase0_out = p0.OUT
    p0.OUT = OUT
    try:
        events = p0.case_input(case)
    finally:
        p0.OUT = phase0_out
    common = [str(ROM), str(events)]
    duration = [str(CONTRACT["boot_frames"]), str(CONTRACT["case_frames"]), p0.LOCK["commit"]]
    p0.run([str(ROOT / "build/reference/Release/sc88_reference_runner.exe"), *common, str(destination / "reference"), *duration], OUT / "logs" / f"{case['id']}-reference.log")
    p0.run([str(BIN / "sc88_register_trace.exe"), *common, str(destination / "export"), *duration], OUT / "logs" / f"{case['id']}-export.log")
    p0.run([str(BIN / "sc88_trace_replay.exe"), str(ROM), str(destination / "export/register.trace"), str(destination / "replay"), p0.LOCK["commit"]], OUT / "logs" / f"{case['id']}-replay.log")
    assert "SC88_REPLAY_COMPLETE" in (OUT / "logs" / f"{case['id']}-replay.log").read_text()
    comparisons = {}
    for name, frames in [("boot",CONTRACT["boot_frames"]), ("native",CONTRACT["case_frames"])]:
        for actual in ["export", "replay"]:
            result = compare(destination / "reference" / f"{name}.pcm", destination / actual / f"{name}.pcm", frames, destination / "export/register.trace", 0 if name == "boot" else CONTRACT["boot_frames"])
            p0.write_json(destination / f"compare-{actual}-{name}.json", result)
            assert result["success"], f"{case['id']} {actual} {name}: {result['first_difference']}"
            comparisons[f"{actual}_{name}"] = result
    assert (destination / "reference/xp-end-state.csv").read_bytes() == (destination / "export/xp-end-state.csv").read_bytes(), "Instrumentation alters end state"
    _, samples = p0.pcm_values(destination / "reference/native.pcm",CONTRACT["case_frames"])
    if case["expect"] == "active":
        assert any(value != 32 for value in samples), f"Case did not exercise audible synthesis: {case['id']}"
    else:
        assert all(value == case["dc"] for value in samples)
    replay = json.loads((destination / "replay/replay.json").read_text())
    assert replay["success"] and replay["cpu_instructions"] == 0 and replay["control_rom_loaded"] is False
    assert replay["frames"] == sum(CONTRACT[name] for name in ["boot_frames","case_frames"])
    assert replay["state_checkpoints"] == 2 + replay["frames"] // CONTRACT["checkpoint_interval"]
    if case["id"] == "lsp_insert":
        assert replay["lsp_return_frames"] > 0, "Insert case did not exercise nonzero cross-frame LSP return"
    print(f"  {case['id']}: exact boot/PCM/state; events={replay['records']}, LSP returns={replay['lsp_return_frames']}", flush=True)
    return {"case":case["id"], "comparisons":comparisons, "replay":replay}


def gate_c():
    results = json.loads((OUT / "comparisons.json").read_text())["cases"]
    for case in CASES[2:]:
        results.append(run_case(case))
        p0.write_json(OUT / "comparisons.json", {"success":len(results) == len(CASES), "cases":results})
    negative_tests()
    print("Running current Phase 0 A-D cumulative regression...", flush=True)
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/run_gate.ps1"), "-Phase", "0", "-Step", "D", "-RomPath", p0.ROM_PATH], OUT / "logs/phase0-regression.log")
    assert json.loads((p0.OUT / "gate-D.json").read_text())["status"] == "通过"
    return ["15_exact_PCM_boot_and_named_state_cases", "multi_note_same_frame_program_GS_reset", "nonzero_LSP_insert_and_feedback", "semantic_and_format_negative_tests", "current_phase0_A_D_regression"]


def gate_d():
    comparisons = json.loads((OUT / "comparisons.json").read_text())
    assert comparisons["success"] and len(comparisons["cases"]) == len(CASES)
    negative = json.loads((OUT / "negative-tests.json").read_text())
    assert negative["success"]
    notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
    assert "observation overlay" in notice and "sc88_trace_replay" in notice
    phase_doc = (ROOT / "docs/phases/phase-01.md").read_text(encoding="utf-8")
    for token in ["SC88TRC1", "CRC-32", "32768", "15", "NOT_TESTED_ON_HARDWARE", "H8"]:
        assert token in phase_doc, f"Missing Phase 1 contract: {token}"
    assert not subprocess.check_output(["git", "-C", str(p0.UPSTREAM), "status", "--porcelain"], text=True).strip()
    for name in ["docs", "host", "reference", "scripts", "verification"]:
        for path in (ROOT / name).rglob("*"):
            assert path.suffix.lower() not in [".trace", ".pcm", ".wav", ".bin", ".mid", ".zip"]
    summary = {"schema_version":1, "phase":1, "status":"通过", "scope":"software", "commit":p0.LOCK["commit"], "trace_version":CONTRACT["version"], "sample_rate":32000, "case_count":len(CASES), "boot_frames_compared":CONTRACT["boot_frames"]*len(CASES), "native_frames_compared":CONTRACT["case_frames"]*len(CASES), "max_absolute_error":0, "rms_error":0, "state_checkpoints":sum(case["replay"]["state_checkpoints"] for case in comparisons["cases"]), "cpu_instructions_in_replay":0, "control_rom_loaded_by_replay":False, "case_metrics":[{"case":item["case"], **item["replay"]} for item in comparisons["cases"]], "negative_tests":[item["name"] for item in negative["tests"]], "previous_phase_regression":"Phase 0 A-D rerun in current C", "hardware_verified":False, "hardware_status":"NOT_TESTED_ON_HARDWARE", "hls_resources":"N/A", "fpga_resources":"N/A", "limit":CONTRACT["coverage_limit"]}
    p0.write_json(OUT / "summary.json", summary)
    p0.write_json(ROOT / "verification/phase-01/summary.json", summary)
    return ["evidence_and_trace_contract_complete", "GPL_observation_overlay_documented", "source_pristine_private_data_excluded", "CPU_decoupling_scope_fixed"]


def trace_records(data):
    offset = 80
    while offset < len(data):
        frame, sequence, kind, chip, address, value, crc = RECORD.unpack_from(data, offset)
        size = 24 + (value if kind in [7,8] else 0)
        yield offset, size, frame, sequence, kind, chip, address, value
        offset += size
    assert offset == len(data)


def repair_record(data, offset, size):
    crc = zlib.crc32(data[offset + 24:offset + size], zlib.crc32(data[offset:offset + 20]))
    struct.pack_into("<I", data, offset + 20, crc)


def resequence(data):
    frame = None
    sequence = 0
    for offset, size, current, *rest in trace_records(data):
        if current != frame:
            frame, sequence = current, 0
        struct.pack_into("<I", data, offset + 8, sequence)
        repair_record(data, offset, size)
        sequence += 1


def negative_tests():
    source = OUT / "cases/piano/export/register.trace"
    original = source.read_bytes()
    locations = list(trace_records(original))
    negative = OUT / "negative"
    negative.mkdir(exist_ok=True)
    tests = []
    write = next(item for item in locations if item[4] == 2 and item[5] == 1 and item[2] > CONTRACT["boot_frames"] and item[6] & 1 and item[6] < 0x2b00)
    read = next(item for item in locations if item[4] == 3)
    checkpoint = next(item for item in locations if item[4] == 7 and item[2] > 0)
    mutations = {}
    dropped = bytearray(original)
    del dropped[write[0]:write[0] + write[1]]
    resequence(dropped)
    mutations["dropped_voice_write"] = dropped
    reordered = bytearray(original)
    staged = {}
    prior = None
    prior_old = None
    for current in locations:
        offset, size, frame, sequence, kind, chip, address, value = current
        if kind == 2 and chip == 1:
            if frame > CONTRACT["boot_frames"] and address < 0x2b00 and address & 1 and prior and prior[2] == frame and prior[4:7] == (2,1,address - 1) and prior[7] != prior_old:
                order_write, previous = current, prior
                break
            prior_old = staged.get(address,0)
            staged[address] = value
        prior = current
    else:
        raise AssertionError("No noncommuting even/odd byte pair for reorder test")
    reordered[previous[0]:order_write[0]+24] = original[order_write[0]:order_write[0]+24] + original[previous[0]:previous[0]+24]
    resequence(reordered)
    mutations["same_frame_write_reordered"] = reordered
    shifted = bytearray(original)
    struct.pack_into("<Q", shifted, write[0], write[2] + 1)
    repair_record(shifted,write[0],write[1])
    mutations["write_frame_shifted"] = shifted
    changed_read = bytearray(original)
    struct.pack_into("<I",changed_read,read[0]+16,read[7]^1)
    repair_record(changed_read,read[0],read[1])
    mutations["read_result_changed"] = changed_read
    missing_reset = bytearray(original[:80] + original[104:])
    resequence(missing_reset)
    mutations["RESET_missing"] = missing_reset
    changed_state = bytearray(original)
    changed_state[checkpoint[0]+24] ^= 1
    repair_record(changed_state,checkpoint[0],checkpoint[1])
    mutations["state_checkpoint_corrupted_valid_CRC"] = changed_state
    writes_only = bytearray(original[:80])
    for offset, size, frame, sequence, kind, *rest in locations:
        if kind not in [3,5]:
            writes_only += original[offset:offset+size]
    resequence(writes_only)
    mutations["reads_and_IRQ_omitted"] = writes_only
    missing_probe = bytearray(original)
    del missing_probe[checkpoint[0]:checkpoint[0]+checkpoint[1]]
    resequence(missing_probe)
    mutations["scheduled_checkpoint_missing"] = missing_probe
    bad_crc = bytearray(original)
    bad_crc[write[0]+16] ^= 1
    mutations["record_CRC_invalid"] = bad_crc
    mutations["truncated_END"] = original[:-8]
    mutations["trailing_record"] = original + original[80:104]
    for name, data in mutations.items():
        path = negative / f"{name}.trace"
        path.write_bytes(data)
        log = OUT / "logs" / f"negative-{name}.log"
        with log.open("w",encoding="utf-8") as stream:
            result = subprocess.run([str(BIN / "sc88_trace_replay.exe"),str(ROM),str(path),str(negative / name),p0.LOCK["commit"]],cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT)
        reason = log.read_text().strip()
        assert result.returncode != 0 and "SC88_REPLAY_COMPLETE" not in reason, f"Trace negative accepted: {name}"
        tests.append({"name":name, "rejected":True, "returncode":result.returncode, "reason":reason})
        print(f"  Negative {name}: rejected",flush=True)
    # Valid Trace plus no Control ROM is a positive independence check.
    wave_directory = negative / "wave-only"
    wave_directory.mkdir(exist_ok=True)
    for path in ROM.glob("sc88pro_wave*.bin"):
        link = wave_directory / path.name
        if not link.exists():
            link.hardlink_to(path)
    assert not (wave_directory / "sc88pro_control.bin").exists()
    p0.run([str(BIN / "sc88_trace_replay.exe"),str(wave_directory),str(source),str(negative / "without_control"),p0.LOCK["commit"]], OUT / "logs/replay-without-control.log")
    expected = OUT / "cases/piano/reference/native.pcm"
    assert compare(expected,negative / "without_control/native.pcm",CONTRACT["case_frames"])["success"]
    tests.append({"name":"positive_replay_without_control_ROM", "passed":True})
    changed_pcm = bytearray(expected.read_bytes())
    changed_pcm[0] ^= 1
    path = negative / "changed.pcm"
    path.write_bytes(changed_pcm)
    difference = compare(expected,path,CONTRACT["case_frames"],source,CONTRACT["boot_frames"])
    p0.write_json(negative / "first-difference.json",difference)
    assert not difference["success"] and difference["first_difference"]["frame"] == 0 and difference["first_difference"]["channel"] == "L"
    assert difference["max_absolute_error"] == 1 and difference["first_difference"]["trace_context"]["last_state_checkpoint"]
    tests.append({"name":"PCM_first_difference_context", "rejected":True})
    for name, data in [("empty_PCM",b""),("last_frame_missing",changed_pcm[:-8])]:
        path = negative / f"{name}.pcm"
        path.write_bytes(data)
        tests.append(p0.must_reject(lambda:compare(expected,path,CONTRACT["case_frames"]),name))
    p0.write_json(OUT / "negative-tests.json", {"success":True, "tests":tests})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, default=1)
    parser.add_argument("--step", choices=list("ABCD"), default="D")
    parser.add_argument("--rom-path", default="")
    args = parser.parse_args()
    if args.phase != 1:
        parser.error("Only Phase 1 is handled here")
    p0.ROM_PATH = args.rom_path
    OUT.mkdir(parents=True, exist_ok=True)
    for destination in [OUT / "summary.json", ROOT / "verification/phase-01/summary.json"]:
        if destination.exists():
            p0.write_json(destination, {"schema_version":1, "phase":1, "status":"未开始", "hardware_verified":False})
    checks = []
    for step in "ABCD"[:"ABCD".index(args.step) + 1]:
        for downstream in "ABCD"["ABCD".index(step):]:
            p0.write_json(OUT / f"gate-{downstream}.json", {"schema_version":1, "phase":1, "step":downstream, "status":"未开始", "scope":"software", "checks":[], "failed_checks":[], "hardware_verified":False})
        p0.write_json(OUT / f"gate-{step}.json", {"schema_version":1, "phase":1, "step":step, "status":"进行中", "scope":"software", "checks":checks, "failed_checks":[], "hardware_verified":False})
        try:
            checks.extend({"A":gate_a, "B":gate_b, "C":gate_c, "D":gate_d}[step]())
        except Exception as error:
            p0.write_json(OUT / f"gate-{step}.json", {"schema_version":1, "phase":1, "step":step, "status":"未通过", "scope":"software", "checks":checks, "failed_checks":[str(error)], "hardware_verified":False})
            raise
        p0.write_json(OUT / f"gate-{step}.json", {"schema_version":1, "phase":1, "step":step, "status":"通过", "scope":"software", "checks":checks, "failed_checks":[], "hardware_verified":False})
        print(f"Phase 1 Gate {step}: passed ({len(checks)} checks)", flush=True)


if __name__ == "__main__":
    main()
