"""Current parameter-player single/pair Voice RTL gates."""
import argparse
import copy
import csv
import json
import re
import struct
import sys

import phase0 as p0
import phase2 as numerical
import phase2_rtl as legacy
import offline_parameter_format as fmt
import offline_phase1

ROOT = p0.ROOT
OUT = ROOT / "build/verification/offline-player/phase-02"
PUBLIC = ROOT / "verification/offline-player/phase-02"
SCOPE = "offline_parameter_single_voice_rtl"
CONTRACT = ROOT / "reference/phase2-rtl-contract.json"


def validate_contract(c, columns):
    base = json.loads((ROOT / "reference/phase2-legacy-rtl-contract.json").read_text(encoding="utf-8"))
    p1 = offline_phase1.CONTRACT
    assert (c["version"], c["scope"], c["top"], c["control_placement"], c["effect_placement"]) == (2, SCOPE, "xp3_parameter_voice", "PC", "PS")
    pc = {f["name"]: f for f in p1["fields"]}
    for field, old in zip(c["state_fields"], base["state_fields"], strict=True):
        assert field["name"] == old["name"] and field["word"] == old["word"] and field["width"] == old["width"]
        assert field["owner"] == ("PC" if field["name"] in pc else "PL")
        assert field["local_preserved_mask"] == pc.get(field["name"], {}).get("local_preserved_mask", 0)
        assert field["update"] == ("host_event_or_parameter_hook" if field["name"] in pc else old["update"])
    expected = [dict(f, word=next(s["word"] for s in base["state_fields"] if s["name"] == f["name"])) for f in p1["fields"]]
    assert c["parameter_fields"] == expected and c["stage_masks"] == p1["stage_masks"]
    expected_ports = [dict(name=name, direction=direction, width=width, signed=False) for name, direction, width in [
        ("param_valid", "input", 1), ("param_ready", "output", 1), ("param_frame", "input", 64), ("param_voice", "input", 6),
        ("param_stage", "input", 3), ("param_mask", "input", 22), ("param_values", "input", 704), ("param_terminal", "input", 1),
        ("param_reason", "input", 3), ("param_req_valid", "output", 1), ("param_req_frame", "output", 64),
        ("param_req_voice", "output", 6), ("param_req_stage", "output", 3), ("param_fault", "output", 1)]]
    assert c["ports"] == base["ports"] + expected_ports
    for key in ["resources", "cycles", "state_ram", "upstream_commit", "part", "sample_rate", "target_clock_ns", "numerical_contract", "measured"]:
        assert c[key] == base[key], key
    assert c["parameter_contract"] == "reference/offline-parameter-contract.json"
    assert c["protocol"]["parameters"] and set(c["protocol"]) == set(base["protocol"]) | {"parameters"}
    assert set(c["required_rtl_tests"]) == set(base["required_rtl_tests"]) | {
        "30_endpoint_pressure_cases", "parameter_PC_PL_joint_states", "parameter_early_late_missing_duplicate_wrong_stage",
        "parameter_one_coefficient", "parameter_width_mask_frame_voice_terminal_fault", "terminal_hold_local_IRQ", "phase1_parameter_binary_equivalence"}
    legacy.validate_contract(base, columns)


def gate_a(checks, summary):
    prerequisite = json.loads((offline_phase1.OUT / "gate-D.json").read_text(encoding="utf-8"))
    assert prerequisite["status"] == "通过" and prerequisite["scope"] == offline_phase1.SCOPE and not prerequisite["failed_checks"]
    offline_phase1.pristine()
    checks.extend(["current_parameter_phase1_D_prerequisite", "pinned_pristine_reference"])
    numerical.OUT = OUT / "reference"
    checks.extend(numerical.gate_a())
    c = json.loads(CONTRACT.read_text(encoding="utf-8"))
    with (numerical.OUT / "golden/fce_dpcm/initial.csv").open(encoding="utf-8", newline="") as stream:
        columns = next(csv.reader(stream))
    validate_contract(c, columns)
    checks.extend(["51_words_PC_PL_owners_and_local_hold_bits", "parameter_hook_ports_masks_widths_and_order", "fixed_resource_timing_cycle_limits"])
    mutations = [
        ("audio_owner", lambda x: x["state_fields"][5].update(owner="PC")),
        ("control_owner", lambda x: x["state_fields"][6].update(owner="PL")),
        ("hold_overwrite", lambda x: x["parameter_fields"][6].update(local_preserved_mask=0)),
        ("stage_width", lambda x: x["ports"][-2].update(width=2)),
        ("frame_deadline", lambda x: x["cycles"].update(frame=3126)),
        ("golden_state_input", lambda x: x["parameter_fields"].append(x["state_fields"][31])),
    ]
    for name, mutate in mutations:
        broken = copy.deepcopy(c)
        mutate(broken)
        try:
            validate_contract(broken, columns)
        except (AssertionError, KeyError):
            checks.append("contract_rejects_" + name)
        else:
            raise AssertionError("Contract checker accepted " + name)
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_parameter_voice_reference.ps1")], OUT / "logs/build-parameter-reference.log")
    binary = ROOT / "build/parameter-voice-reference/Release/sc88_voice_vectors.exe"
    for kind, extra in [("golden", []), ("pressure", ["--pressure"])]:
        destination = OUT / "parameter-reference" / kind
        p0.run([str(binary), str(destination), *extra], OUT / "logs" / f"parameter-{kind}.log")
        if kind == "pressure":
            p0.run([str(numerical.BIN / "sc88_voice_vectors.exe"), str(numerical.OUT / kind), *extra], OUT / "logs/pressure-reference.log")
        names = [row["case"] for row in numerical.rows(destination / "manifest.csv")]
        assert len(names) == (60 if kind == "golden" else 30)
        hooks = terminals = 0
        for name in names:
            for filename in ["initial.csv", "expected.csv", "events.csv", "rom-reads.csv", "stages.csv", "source-before.csv", "source-after.csv"]:
                assert (destination / name / filename).read_bytes() == (numerical.OUT / kind / name / filename).read_bytes(), (name, filename)
            for row in numerical.rows(destination / name / "parameters.csv"):
                stage, mask = int(row["stage"]), int(row["mask"])
                assert not mask & ~fmt.STAGE_MASKS[stage]
                assert -1 <= int(row["terminal"]) <= 4 and (int(row["terminal"]) == -1 or stage == 4)
                for field in c["parameter_fields"]:
                    value = int(row[f"value{field['bit']}"])
                    assert 0 <= value < 1 << field["width"] and not value & field["local_preserved_mask"]
                    assert mask & (1 << field["bit"]) or value == 0
                hooks += 1
                terminals += int(row["terminal"]) != -1
        summary[kind + "_reference"] = dict(cases=len(names), frames=len(names)*256, hooks=hooks, terminal_candidates=terminals, unchanged_reference_exact=True)
    checks.append("90_parameter_hook_cases_unchanged_state_ROM_and_intermediates")
    real = OUT / "parameter-reference/trace-piano"
    trace = numerical.CONTRACT["trace_case"]
    original_trace = ROOT / "build/verification/phase-01/cases/piano/export/register.trace"
    p0.run([str(binary.with_name("sc88_voice_trace_probe.exe")), str(ROOT / "private/roms"), str(original_trace), str(real), p0.LOCK["commit"], str(trace["first_voice"])], OUT / "logs/parameter-trace-piano.log")
    for filename in ["voice-initial.csv", "voice-expected.csv", "voice-controls.csv", "voice-rom-reads.csv", "voice-stages.csv", "voice-source-before.csv", "voice-source-after.csv", "native.pcm", "boot.pcm"]:
        assert (real / filename).read_bytes() == (numerical.OUT / "trace-piano" / filename).read_bytes(), filename
    observed = {}
    for row in numerical.rows(real / "parameters.csv"):
        if int(row["mask"]) or int(row["terminal"]) >= 0:
            key = (int(row["frame"]), int(row["voice"]), int(row["stage"]))
            assert key not in observed
            observed[key] = (int(row["mask"]), int(row["terminal"]), [int(row[f"value{i}"]) for i in range(22)])
    records = {}
    parameter_file = offline_phase1.OUT / "cases/piano/export/song.scp"
    for event, payload in fmt.events(parameter_file, p0.LOCK["commit"]):
        frame, _, kind, stage, _, voice, mask, _ = event
        if frame < trace["boot_frames"] or kind not in [6, 7]:
            continue
        key = (frame, voice, stage)
        packet = records.setdefault(key, [0, -1, [0]*22])
        if kind == 6:
            packet[0] = mask
            values = iter(struct.unpack(f"<{mask.bit_count()}I", payload))
            for i in range(22):
                if mask & (1 << i):
                    packet[2][i] = next(values)
        else:
            packet[1] = payload[0]
    assert observed == {key: tuple(packet) for key, packet in records.items()}, "SC88PAR1 PC values differ from unchanged Voice hook observations"
    summary["piano_reference"] = dict(frames=256000, state_words=51, changed_hooks=len(records), unchanged_reference_exact=True, parameter_binary_exact=True)
    checks.extend(["piano_256000_frames_unchanged_reference_exact", "phase1_SC88PAR1_PC_fields_and_terminal_candidates_exact"])
    return c


def inspect_b(checks, summary):
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    source = (ROOT / "hardware/rtl/xp3_parameter_voice.sv").read_text(encoding="utf-8")
    actual = {}
    for direction, signed, high, name in re.findall(r"(input|output)\s+logic\s+(signed\s+)?(?:\[(\d+):0\]\s+)?(\w+)", source.split(");", 1)[0]):
        actual[name] = dict(direction=direction, signed=bool(signed), width=int(high)+1 if high else 1)
    assert actual == {p["name"]:{k:p[k] for k in ["direction", "signed", "width"]} for p in contract["ports"]}, "Parameter RTL ports differ from version 2 contract"
    assert not any(unit in source for unit in ["xp3_ramp_math", "xp3_control_math", "xp3_source_control", "xp3_ramp_service"])
    synthetic = json.loads((OUT / "voice-synthetic/summary.json").read_text(encoding="utf-8"))
    pressure = json.loads((OUT / "voice-pressure/summary.json").read_text(encoding="utf-8"))
    implementation = json.loads((OUT / "voice-implementation/summary.json").read_text(encoding="utf-8"))
    assert synthetic["success"] and pressure["success"] and implementation["success"]
    assert synthetic["cases"] == 60 and synthetic["frames"] == 15360 and synthetic["reset_positions"] == 512 and synthetic["stalls_passed"]
    assert pressure["cases"] == 30 and pressure["frames"] == 7680 and len(synthetic["negative_faults_detected"]) == 16
    from test_parameter_voice_implementation import inspect
    core = inspect()
    assert core == implementation["core"]
    summary.update(resources={k:core[k] for k in ["LUT", "FF", "DSP", "BRAM18", "BRAM36"]},
                   timing={k:core[k] for k in ["WNS_ns", "WHS_ns", "WPWS_ns"]},
                   worst_cycles=dict(single=max(synthetic["single_cycles"], pressure["single_cycles"]),
                                     pair=max(synthetic["pair_cycles"], pressure["pair_cycles"]), scope="synthetic_and_endpoint_nominal_ROM_and_ready_parameters"))
    assert summary["worst_cycles"]["single"] <= 44 and summary["worst_cycles"]["pair"] <= 88
    checks.extend(["all_parameter_top_ports_match_contract", "no_PL_ramp_curve_or_coefficient_generation",
                   "60_cases_continuous_PC_PL_state_ROM_and_stages_exact", "30_endpoint_pressure_cases_exact_within_44_88",
                   "parameter_ROM_wait_backpressure_and_512_reset_positions", "16_real_data_protocol_and_timing_faults_detected",
                   "complete_core_routed_resources_setup_hold_pulse_width_pass"])


def gate_b(checks, summary):
    for script, extra in [("test_parameter_voice.py", []), ("test_parameter_voice.py", ["--kind", "pressure"]), ("test_parameter_voice_implementation.py", [])]:
        label = "pressure" if extra else script
        p0.run([sys.executable, "-X", "utf8", str(ROOT / "host" / script), *extra], OUT / "logs" / (label + ".log"))
    inspect_b(checks, summary)


def inspect_c(checks, summary):
    for name in ["filter_tva", "interpolation", "voice_state", "pair_filter", "wave_source"]:
        assert json.loads((OUT / "components" / name / "summary.json").read_text(encoding="utf-8"))["success"], name
    piano = json.loads((OUT / "voice-piano/summary.json").read_text(encoding="utf-8"))
    irq = json.loads((OUT / "voice-irq/summary.json").read_text(encoding="utf-8"))
    assert piano["success"] and piano["frames"] == 256000 and piano["stages"] > 0 and piano["parameter_hooks"] > 0 and piano["single_cycles"] <= 44
    assert irq["success"] and irq["cases"] == 22 and irq["frames"] == 1408 and irq["original_reference_exact"] and irq["phase1_binary_exact"]
    assert irq["nominal"]["single_cycles"] <= 44 and irq["nominal"]["pair_cycles"] <= 88
    for phase, directory, scope in [(0, p0.OUT, "software"), (1, offline_phase1.OUT, offline_phase1.SCOPE)]:
        previous = json.loads((directory / "gate-D.json").read_text(encoding="utf-8"))
        assert previous["status"] == "通过" and not previous["failed_checks"]
        assert previous["scope"] == scope, f"Phase {phase} cumulative evidence has a different scope"
    summary["piano_RTL"] = piano
    summary["IRQ_RTL"] = irq
    summary["worst_cycles"].update(single=max(summary["worst_cycles"]["single"], piano["single_cycles"], irq["nominal"]["single_cycles"]),
                                   pair=max(summary["worst_cycles"]["pair"], irq["nominal"]["pair_cycles"]), scope="synthetic_piano_endpoint_and_IRQ_nominal_ROM_and_ready_parameters")
    checks.extend(["five_retained_numeric_components_current_reference_boundaries_stalls_reset", "piano_256000_frames_full_51_words_ROM_and_stages_exact",
                   "22_four_voice_IRQ_hold_terminal_phase_pair_cases_original_and_SC88PAR1_exact", "four_voice_IRQ_context_chained_under_parameter_and_ROM_stalls",
                   "current_parameter_phase1_A_D_and_phase0_A_D_cumulative"])


def gate_c(checks, summary):
    for name in ["filter_tva", "interpolation", "voice_state", "pair_filter", "wave_source"]:
        code = (f"import sys; sys.path.insert(0,{str(ROOT/'host')!r}); import test_{name} as t; from pathlib import Path; "
                f"t.OUT=Path({str(OUT/'components'/name)!r}); t.REFERENCE=Path({str(OUT/'reference')!r}); t.main()")
        p0.run([sys.executable, "-X", "utf8", "-c", code], OUT / "logs" / f"component-{name}.log")
    p0.run([sys.executable, "-X", "utf8", str(ROOT / "host/test_parameter_voice.py"), "--kind", "piano"], OUT / "logs/piano-RTL.log")
    p0.run([sys.executable, "-X", "utf8", str(ROOT / "host/test_parameter_irq.py")], OUT / "logs/IRQ-RTL.log")
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/run_gate.ps1"), "-Phase", "1", "-Step", "D"], OUT / "logs/phase1-cumulative.log")
    inspect_c(checks, summary)


def gate_d(checks, summary):
    for step in "ABC":
        evidence = json.loads((OUT / f"gate-{step}.json").read_text(encoding="utf-8"))
        assert evidence["status"] == "通过" and evidence["scope"] == SCOPE and not evidence["failed_checks"]
    from test_parameter_voice_implementation import inspect
    core = inspect()
    assert summary["resources"] == {k:core[k] for k in ["LUT", "FF", "DSP", "BRAM18", "BRAM36"]}
    assert summary["timing"] == {k:core[k] for k in ["WNS_ns", "WHS_ns", "WPWS_ns"]}
    for source in ["hardware/rtl/xp3_parameter_voice.sv", "hardware/sim/tb_parameter_voice.sv", "host/voice_reference/parameter_voice_probe.h", "host/voice_reference/parameter_irq_vectors.cpp"]:
        assert "SPDX-License-Identifier: GPL-3.0-only" in (ROOT / source).read_text(encoding="utf-8")
    assert "Phase 2 handwritten RTL" in (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8") and (ROOT / "LICENSE.md").exists()
    offline_phase1.pristine()
    assert summary["hardware_verified"] is False and summary["hardware_status"] == "NOT_TESTED_ON_HARDWARE"
    checks.extend(["A_B_C_current_parameter_evidence_consistent", "GPL_reference_and_private_artifact_boundary", "routed_resource_timing_cycles_and_no_hardware_claim_audit"])
    summary["verified_logical_frames"] = summary["golden_reference"]["frames"] + summary["pressure_reference"]["frames"] + summary["piano_RTL"]["frames"] + summary["IRQ_RTL"]["frames"]
    summary["status"] = "通过"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, choices=[2], default=2)
    parser.add_argument("--step", choices=list("ABCD"), default="A")
    parser.add_argument("--rom-path", default="")
    args = parser.parse_args()
    if args.rom_path:
        parser.error("Import ROMs through Phase 0")
    summary = dict(schema_version=1, phase=2, scope=SCOPE, RTL_contract_version=2, control_field_schema=1, status="进行中", gate_status={s:"未开始" for s in "ABCD"}, hardware_verified=False,
                   hardware_status="NOT_TESTED_ON_HARDWARE", resources="UNVERIFIED", timing="UNVERIFIED", worst_cycles="UNVERIFIED")
    checks=[]
    def write(step, status, failures):
        p0.write_json(OUT / f"gate-{step}.json", dict(schema_version=1, phase=2, step=step, scope=SCOPE, status=status, checks=list(checks), failed_checks=failures, hardware_verified=False))
    for step in "ABCD":
        write(step, "未开始", [])
    step="A"
    try:
        for step in "ABCD"[:"ABCD".index(args.step)+1]:
            write(step,"进行中",[])
            if step=="A":
                gate_a(checks,summary)
            elif step=="B":
                gate_b(checks,summary)
            elif step=="C":
                gate_c(checks,summary)
            elif step=="D":
                gate_d(checks,summary)
            else:
                raise RuntimeError(f"Current parameter RTL Gate {step} is not implemented")
            summary["gate_status"][step]="通过"
            write(step,"通过",[])
            print(f"Phase 2 parameter RTL Gate {step}: passed ({len(checks)} checks)",flush=True)
    except Exception as error:
        summary["status"]="未通过"
        summary["gate_status"][step]="未通过"
        write(step,"未通过",[str(error)])
        raise
    finally:
        p0.write_json(OUT / "summary.json",summary)
        p0.write_json(PUBLIC / "summary.json",summary)


if __name__=="__main__":
    main()
