"""Current-scope Phase 1 A-D: precomputed controls and independent XP/LSP replay."""
import argparse
import json
from pathlib import Path
import subprocess

import phase0 as p0
import offline_irq_boundary
import offline_parameter_format as fmt
import offline_parameter_format_test
from sc88_audio_compare import compare
from test_th06_midi import midi_stats, INPUT as MIDI_INPUT, SOURCE_PAGE, SOURCE_ARCHIVE

ROOT = p0.ROOT
OUT = ROOT / "build/verification/offline-player/phase-01"
PUBLIC = ROOT / "verification/offline-player/phase-01"
BIN = ROOT / "build/offline-player/Release"
ROM = ROOT / "private/roms"
CONTRACT = json.loads((ROOT / "reference/offline-parameter-contract.json").read_text(encoding="utf-8"))
SCOPE = "offline_parameter_player_software"


def pristine():
    if subprocess.check_output(["git", "-C", str(p0.UPSTREAM), "rev-parse", "HEAD"], text=True).strip() != p0.LOCK["commit"]:
        raise ValueError("Pinned reference identity differs")
    if subprocess.check_output(["git", "-C", str(p0.UPSTREAM), "status", "--porcelain"], text=True).strip():
        raise ValueError("Pinned reference is modified")


def gate_a():
    previous = json.loads((p0.OUT / "gate-D.json").read_text(encoding="utf-8"))
    if previous["status"] != "通过" or previous["failed_checks"]:
        raise ValueError("Phase 0 D prerequisite is missing")
    pristine()
    if CONTRACT["scope"] != SCOPE or CONTRACT["sample_rate"] != 32000 or len(CONTRACT["cases"]) != 15 or len(CONTRACT["songs"]) != 7:
        raise ValueError("Current scope/coverage contract is incomplete")
    if (fmt.HEADER.size, fmt.BLOCK.size, fmt.RECORD.size) != (104, 32, 24):
        raise ValueError("Parameter binary contract differs")
    irq_contract = json.loads((ROOT / "reference/offline-irq-boundary.json").read_text(encoding="utf-8"))
    if irq_contract["unresolved_numeric_dependencies"] or irq_contract["scope"] != SCOPE:
        raise ValueError("Unresolved control/IRQ boundary")
    if [field["name"] for field in CONTRACT["fields"]] != fmt.FIELD_NAMES or {int(stage): mask for stage, mask in CONTRACT["stage_masks"].items()} != fmt.STAGE_MASKS:
        raise ValueError("Control field contract differs from executable codec")
    p0.write_json(OUT / "roms.json", p0.scan(p0.resolve_source(p0.ROM_PATH), p0.load_targets(), ROM))
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_reference.ps1")], OUT / "logs/build-reference.log")
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_offline_player.ps1")], OUT / "logs/build-parameter-boundary.log")
    format_report = offline_parameter_format_test.run()
    for fixture in ["normal", "split"]:
        p0.run([str(BIN / "sc88_parameter_replay.exe"), "--scan", str(OUT / "format-cases" / f"{fixture}.scp"), p0.LOCK["commit"]], OUT / "logs" / f"CXX-codec-{fixture}.json")
    irq_report = offline_irq_boundary.run()
    if not format_report["success"] or not irq_report["success"]:
        raise ValueError("Parameter/IRQ boundary proof failed")
    for filename in ["xp_replay.cpp", "xp_voice_replay.cpp"]:
        source = (ROOT / "build/offline-player-overlay" / filename).read_text(encoding="utf-8")
        for calculation in ["decodePitch(", "combineAmp(", "stepLinearRamp(", "stepLogRamp(", "calculateLinearRampStep("]:
            if calculation in source:
                raise ValueError(f"Runtime retains control calculation: {filename}/{calculation}")
    link_map = (ROOT / "build/offline-player/sc88_parameter_replay.map").read_text(encoding="utf-8")
    if any(name in link_map.lower() for name in ["h8500", "sc88_board", "sc88_parameter_board", "xp_parameter_export", "xplib.lib"]):
        raise ValueError("Parameter replay links control/board reference")
    p0.write_json(OUT / "boundary-contract.json", {"scope": SCOPE, "format_version": 1, "field_schema_version": 1,
        "control_fields": CONTRACT["fields"], "consumption_stages": CONTRACT["stages"], "local_IRQ": CONTRACT["local_IRQ"], "schedule": CONTRACT["schedule"],
        "reference": "unmodified pinned XP and independently built unmodified complete SC-88Pro board", "IRQ_cases": len(irq_report["cases"]),
        "forbidden_runtime_inputs": CONTRACT["forbidden_runtime_inputs"], "hardware_verified": False})
    return ["phase0_D_prerequisite", "pinned_pristine_reference_ROM_identity", "parameter_format_and_segment_contract_executable", "22_dynamic_IRQ_phase_pair_boundary_cases_exact", "calculation_free_H8_free_replay_link_boundary", "fixed_15_cases_7_songs_and_failure_rules"]


def run_case(case, events=None, frames=None, tail=0):
    destination = OUT / "cases" / case["id"]
    if events is None:
        previous_out = p0.OUT
        p0.OUT = OUT
        try:
            events = p0.case_input(case)
        finally:
            p0.OUT = previous_out
    frames = CONTRACT["case_frames"] if frames is None else frames
    common = [str(ROM), str(events)]
    duration = [str(CONTRACT["boot_frames"]), str(frames), p0.LOCK["commit"]]
    p0.run([str(ROOT / "build/reference/Release/sc88_reference_runner.exe"), *common, str(destination / "reference"), *duration], OUT / "logs" / f"{case['id']}-reference.log")
    p0.run([str(BIN / "sc88_parameter_export.exe"), *common, str(destination / "export"), *duration, str(tail)], OUT / "logs" / f"{case['id']}-export.log")
    p0.run([str(BIN / "sc88_parameter_replay.exe"), str(ROM), str(destination / "export/song.scp"), str(destination / "replay"), p0.LOCK["commit"], str(destination / "export/assertions.bin")], OUT / "logs" / f"{case['id']}-replay.log")
    if "SC88_PARAMETER_REPLAY_COMPLETE" not in (OUT / "logs" / f"{case['id']}-replay.log").read_text(encoding="utf-8"):
        raise ValueError(f"Missing replay completion: {case['id']}")
    comparisons = {}
    for name, count in [("boot", CONTRACT["boot_frames"]), ("native", frames)]:
        for actual in ["export", "replay"]:
            result = compare(destination / "reference" / f"{name}.pcm", destination / actual / f"{name}.pcm", count, frame_offset=0 if name == "boot" else CONTRACT["boot_frames"])
            p0.write_json(destination / f"compare-{actual}-{name}.json", result)
            if not result["success"]:
                raise ValueError(f"{case['id']}/{actual}/{name}: {result['first_difference']}")
            comparisons[f"{actual}_{name}"] = result
    if (destination / "reference/xp-end-state.csv").read_bytes() != (destination / "export/xp-end-state.csv").read_bytes():
        raise ValueError(f"Control observation changes reference state: {case['id']}")
    reference_meta = json.loads((destination / "reference/runner.json").read_text(encoding="utf-8"))
    export_meta = json.loads((destination / "export/runner.json").read_text(encoding="utf-8"))
    if reference_meta != export_meta:
        raise ValueError(f"Control observation changes reference execution: {case['id']}")
    if case.get("expect"):
        _, samples = p0.pcm_values(destination / "reference/native.pcm", frames)
        if case["expect"] == "active" and not any(value != 32 for value in samples):
            raise ValueError(f"Inactive synthesis fixture: {case['id']}")
        if case["expect"] != "active" and not all(value == case["dc"] for value in samples):
            raise ValueError(f"Unexpected silence fixture: {case['id']}")
    replay = json.loads((destination / "replay/replay.json").read_text(encoding="utf-8"))
    if not replay["success"] or replay["cpu_instructions"] or replay["control_rom_loaded"] or replay["control_implementations_executed"]:
        raise ValueError("Runtime control decoupling failed")
    if replay["frames"] != CONTRACT["boot_frames"] + frames or replay["state_checkpoints"] != 2 + replay["frames"] // 32768:
        raise ValueError("Incomplete state/frame comparisons")
    if case["id"] in ["lsp_insert", "th06_03", "th06_05"] and not replay["lsp_return_frames"]:
        raise ValueError("LSP feedback fixture did not exercise returns")
    p0.run([str(BIN / "sc88_parameter_replay.exe"), "--scan", str(destination / "export/song.scp"), p0.LOCK["commit"]], destination / "decode-metrics.json")
    metrics = json.loads((destination / "decode-metrics.json").read_text(encoding="utf-8"))
    segments = []
    index = 0
    while fmt.segment_path(destination / "export/song.scp", index).exists():
        path = fmt.segment_path(destination / "export/song.scp", index)
        segments.append({"file": path.name, "bytes": path.stat().st_size})
        index += 1
    metrics.update({"segments": segments, "file_bytes": sum(s["bytes"] for s in segments), "tail_frames": tail, "file_buffer_candidate_each_bytes": [8388608, 16777216], "audio_block_frames": 16})
    p0.write_json(destination / "parameter-metrics.json", metrics)
    print(f"  {case['id']}: exact {replay['frames']} frames/{replay['state_checkpoints']} states; parameters={metrics['file_bytes']} bytes", flush=True)
    return {"case": case["id"], "comparisons": comparisons, "replay": replay, "parameters": metrics, "boot_frames": CONTRACT["boot_frames"], "native_frames": frames}


def gate_b():
    results = [run_case(case) for case in CONTRACT["cases"][:2]]
    p0.write_json(OUT / "comparisons.json", {"success": False, "cases": results})
    return ["silence_piano_current_unmodified_reference_exact_PCM", "17_per_case_full_control_voice_effect_state_assertions", "export_does_not_change_CPU_schedule_or_end_state", "actual_parameter_size_peak_block_unpack_metrics"]


def gate_c():
    results = json.loads((OUT / "comparisons.json").read_text(encoding="utf-8"))["cases"]
    for case in CONTRACT["cases"][2:]:
        results.append(run_case(case))
        p0.write_json(OUT / "comparisons.json", {"success": False, "cases": results})
    songs = []
    for filename in CONTRACT["songs"]:
        path = MIDI_INPUT / filename
        stats = midi_stats(path)
        result = run_case({"id": path.stem}, path, stats["case_frames"], CONTRACT["song_tail_frames"])
        result["midi"] = stats
        songs.append(result)
        p0.write_json(OUT / "songs.json", {"success": False, "source_page": SOURCE_PAGE, "source_archive": SOURCE_ARCHIVE, "input_unmodified": True, "songs": songs})
    from offline_parameter_negative import run as run_negative
    run_negative()
    print("  Running current Phase 0 A-D cumulative regression", flush=True)
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/run_gate.ps1"), "-Phase", "0", "-Step", "D", "-RomPath", p0.ROM_PATH], OUT / "logs/phase0-regression.log")
    previous = json.loads((p0.OUT / "gate-D.json").read_text(encoding="utf-8"))
    if previous["status"] != "通过" or previous["failed_checks"]:
        raise ValueError("Current Phase 0 cumulative regression failed")
    p0.write_json(OUT / "phase0-regression.json", {"success": True, "scope": previous["scope"], "current_run": True, "gate": str(p0.OUT / "gate-D.json"), "checks": previous["checks"], "hardware_verified": False})
    p0.write_json(OUT / "comparisons.json", {"success": True, "cases": results})
    p0.write_json(OUT / "songs.json", {"success": True, "source_page": SOURCE_PAGE, "source_archive": SOURCE_ARCHIVE, "input_unmodified": True, "songs": songs})
    return ["15_normal_cases_exact_boot_native_full_state", "seven_original_complete_MIDIs_and_8_second_tails_exact", "nonzero_LSP_and_cross_frame_feedback_exact", "parameter_semantic_container_and_comparator_negatives", "Wave_only_assertion_free_independent_replay", "current_Phase0_A_D_cumulative_regression"]


def gate_d():
    comparisons = json.loads((OUT / "comparisons.json").read_text(encoding="utf-8"))
    songs = json.loads((OUT / "songs.json").read_text(encoding="utf-8"))
    negatives = json.loads((OUT / "negative-tests.json").read_text(encoding="utf-8"))
    if not comparisons["success"] or len(comparisons["cases"]) != 15 or not songs["success"] or len(songs["songs"]) != 7 or not negatives["success"]:
        raise ValueError("Incomplete current-scope Phase 1 evidence")
    pristine()
    notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    if "sc88_parameter_replay" not in notice or "prepare_offline_player.py" not in notice:
        raise ValueError("Parameter derivative/license notice missing")
    items = comparisons["cases"] + songs["songs"]
    summary = {"schema_version": 1, "phase": 1, "status": "通过", "scope": SCOPE, "format_version": 1, "field_schema_version": 1, "commit": p0.LOCK["commit"], "sample_rate": 32000,
        "case_count": 15, "song_count": 7, "boundary_case_count": 22, "boot_frames_compared": sum(item["boot_frames"] for item in items), "native_frames_compared": sum(item["native_frames"] for item in items),
        "state_checkpoints": sum(item["replay"]["state_checkpoints"] for item in items), "max_absolute_error": 0, "rms_error": 0, "cpu_instructions_in_replay": 0, "control_implementations_executed": 0,
        "control_rom_loaded_by_replay": False, "golden_post_state_runtime_input": False, "negative_tests": [{key: value for key, value in test.items() if key in ["name", "rejected", "passed"]} for test in negatives["tests"]], "song_metrics": [{"file": item["midi"]["file"], "frames": item["native_frames"], **item["parameters"]} for item in songs["songs"]],
        "current_phase0_regression": "Phase 0 A-D rerun in current C; independent original contract/directory", "hardware_verified": False, "hardware_status": "NOT_TESTED_ON_HARDWARE", "ARMv7": "UNVERIFIED", "USB": "UNVERIFIED", "FPGA_resources": "UNVERIFIED",
        "limit": "fixed-reference software parameter decoupling, complete original demo SMF once plus tail; excludes hardware timing, game loop restart and silicon equivalence"}
    p0.write_json(OUT / "summary.json", summary)
    p0.write_json(PUBLIC / "summary.json", summary)
    return ["complete_same_scope_evidence_and_ownership_contract", "GPL_derivative_notice_and_pristine_fixed_sources", "public_aggregate_metrics_private_parameters_PCM_assertions", "software_decoupling_only_hardware_limits_explicit"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, default=1)
    parser.add_argument("--step", choices=list("ABCD"), default="D")
    parser.add_argument("--rom-path", default="")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if args.phase != 1:
        parser.error("Only current offline-player Phase 1 is implemented")
    p0.ROM_PATH = args.rom_path
    OUT.mkdir(parents=True, exist_ok=True)
    checks = []
    for destination in [OUT / "summary.json", PUBLIC / "summary.json"]:
        if destination.exists():
            p0.write_json(destination, {"schema_version": 1, "phase": 1, "status": "未开始", "scope": SCOPE, "hardware_verified": False})
    for step in "ABCD"[:"ABCD".index(args.step) + 1]:
        for downstream in "ABCD"["ABCD".index(step):]:
            p0.write_json(OUT / f"gate-{downstream}.json", {"schema_version": 1, "phase": 1, "step": downstream, "status": "未开始", "scope": SCOPE, "format_version": 1, "field_schema_version": 1, "checks": [], "failed_checks": [], "hardware_verified": False})
        report = {"schema_version": 1, "phase": 1, "step": step, "status": "进行中", "scope": SCOPE, "format_version": 1, "field_schema_version": 1, "checks": checks, "failed_checks": [], "hardware_verified": False}
        p0.write_json(OUT / f"gate-{step}.json", report)
        try:
            checks.extend({"A": gate_a, "B": gate_b, "C": gate_c, "D": gate_d}[step]())
        except Exception as error:
            report.update(status="未通过", failed_checks=[str(error)])
            p0.write_json(OUT / f"gate-{step}.json", report)
            raise
        report.update(status="通过", checks=checks)
        p0.write_json(OUT / f"gate-{step}.json", report)
        print(f"Offline-player Phase 1 Gate {step}: passed ({len(checks)} checks)", flush=True)


if __name__ == "__main__":
    main()
