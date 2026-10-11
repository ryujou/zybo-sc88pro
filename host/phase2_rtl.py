"""Phase 2 RTL contract gate; reference evidence is isolated from historical HLS runs."""
import argparse
import copy
import csv
import json
import re
import sys

import phase2 as reference

ROOT = reference.ROOT
OUT = ROOT / "build/verification/phase-02-rtl"


def validate_contract(contract, columns):
    numeric = reference.CONTRACT
    assert contract["upstream_commit"] == numeric["upstream_commit"]
    assert contract["part"] == numeric["part"] == "xc7z010clg400-1"
    assert contract["sample_rate"] == 32000 and contract["target_clock_ns"] == 10
    assert contract["control_placement"] == "PL", "PS migration requires independent numerical boundary validation"
    expected = {}
    for name, width in numeric["state_widths"].items():
        count = 8 if name == "waveCircularBuffer_0800" else 4 if name == "mixer_3a00" else 1
        for index in range(count):
            expected[f"{name}[{index}]" if count > 1 else name] = width
    fields = contract["state_fields"]
    assert len(fields) == len(expected) and {f["name"]: f["width"] for f in fields} == expected, "State width/coverage mismatch"
    assert {f["word"] for f in fields} == set(range(len(fields))), "State words overlap or have holes"
    observed = {name.split("].", 1)[1] for name in columns if name.startswith("voice[0].")}
    assert observed == set(expected), "Golden state columns differ from RTL layout"
    ram = contract["state_ram"]
    assert (ram["voices"], ram["word_bits"], ram["words_per_voice"], ram["banks"], ram["bank_depth"], ram["read_latency"]) == (64, 32, 64, 8, 512, 1)
    addresses = set()
    for voice in range(64):
        for field in fields:
            assert field["owner"] == "PL" and field["reset"] == 0 and field["storage"] == "unsigned_bits"
            assert field["update"] in {"host_event_or_launch", "filter_or_release_clear", "pre_source_tva", "source", "source_decode_or_ramp", "host_event"}
            word = field["word"]
            address = (word % 8, voice * 8 + word // 8)
            assert address not in addresses and address[1] < ram["bank_depth"]
            addresses.add(address)
    resource = contract["resources"]
    assert resource["device"] == dict(LUT=17600, FF=35200, DSP=80, BRAM18=120)
    assert resource["core_max"] == dict(LUT=12000, FF=16000, DSP=32, BRAM18=24), "Core budget changed"
    for name, capacity in resource["device"].items():
        assert resource["core_max"][name] + resource["system_reserve"][name] == capacity
        assert resource["system_reserve"][name] > 0
    assert ram["banks"] <= resource["core_max"]["BRAM18"]
    cycles = contract["cycles"]
    assert cycles["frame"] == 3125 and cycles["voices"] == 64
    assert cycles["single_max"] == 44 and cycles["pair_max"] == 88
    assert cycles["single_max"] * 64 + cycles["system_reserve"] == cycles["frame"]
    assert cycles["pair_max"] * 32 + cycles["system_reserve"] == cycles["frame"]
    assert cycles["rom_outstanding"] == 1 and cycles["nominal_rom_response_cycles"] == 1
    assert cycles["reset_max"] == ram["bank_depth"]
    ports = {port["name"]: port for port in contract["ports"]}
    assert len(ports) == len(contract["ports"]), "Duplicate port"
    for port in ports.values():
        assert port["direction"] in {"input", "output"} and 1 <= port["width"] <= 64
        assert isinstance(port["signed"], bool)
    for name, direction, width in [
        ("clk", "input", 1), ("rst", "input", 1), ("ready", "output", 1),
        ("cmd_frame", "input", 64), ("cmd_voice", "input", 6), ("cmd_pair", "input", 1),
        ("done_frame", "output", 64), ("done_voice", "output", 6),
        ("cfg_word", "input", 6), ("cfg_voice", "input", 6), ("cfg_wdata", "input", 32),
        ("cfg_rsp_data", "output", 32), ("rom_req_address", "output", 24),
        ("rom_req_cs", "output", 3), ("rom_rsp_data", "input", 8),
    ]:
        assert ports[name]["direction"] == direction and ports[name]["width"] == width, f"Port mismatch: {name}"
    for channel, source in [("cmd", "input"), ("done", "output"), ("cfg", "input"), ("cfg_rsp", "output"), ("rom_req", "output"), ("rom_rsp", "input")]:
        for suffix, direction in [("valid", source), ("ready", "output" if source == "input" else "input")]:
            assert ports[f"{channel}_{suffix}"]["width"] == 1 and ports[f"{channel}_{suffix}"]["direction"] == direction
    for role in ("owner", "partner"):
        for kind, width in [("sample", 20), ("prior", 24), ("output", 24)]:
            port = ports[f"done_{kind}_{role}"]
            assert port["signed"] and port["width"] == width and port["direction"] == "output"
    assert set(contract["protocol"]) == {"handshake", "commands", "frame", "config", "rom", "completion", "reset", "stalls"}
    assert all(contract["protocol"].values())
    assert set(contract["required_rtl_tests"]) == {
        "60_synthetic_cases", "piano_256000_frames", "all_state_words", "rom_address_and_order",
        "interpolation_filter_tva_stages", "irq_arbitration", "one_coefficient", "one_state_bit",
        "one_rom_byte", "one_update_phase", "rom_wait_0_1_7_31", "done_backpressure",
        "reset_idle_request_response_done", "duplicate_or_missing_rom_detection", "phase0_phase1_cumulative",
    }
    assert contract["measured"] == dict(resources="UNVERIFIED", timing="UNVERIFIED", worst_cycles="UNVERIFIED", hardware="NOT_TESTED_ON_HARDWARE")


def gate_a(checks):
    contract = json.loads((ROOT / "reference/phase2-legacy-rtl-contract.json").read_text(encoding="utf-8"))
    # Call the reference generator without its legacy main(), which owns the HLS evidence paths.
    reference.OUT = OUT / "reference"
    checks.extend(reference.gate_a())
    golden = reference.OUT / "golden"
    with (golden / "fce_dpcm/initial.csv").open(encoding="utf-8", newline="") as stream:
        columns = next(csv.reader(stream))
    validate_contract(contract, columns)
    checks.extend(["RTL_ports_and_handshakes_declared", "all_51_state_words_owned_and_banked", "device_and_system_resource_reserve", "single_pair_and_frame_cycle_limits"])
    mutations = [
        ("state_width", lambda c: c["state_fields"][0].update(width=19)),
        ("state_overlap", lambda c: c["state_fields"][1].update(word=0)),
        ("unvalidated_PS_owner", lambda c: c["state_fields"][0].update(owner="PS")),
        ("resource_excess", lambda c: c["resources"]["core_max"].update(LUT=17601)),
        ("pair_deadline", lambda c: c["cycles"].update(pair_max=89)),
        ("missing_handshake", lambda c: c.update(ports=[p for p in c["ports"] if p["name"] != "rom_rsp_ready"])),
    ]
    for name, mutate in mutations:
        broken = copy.deepcopy(contract)
        mutate(broken)
        try:
            validate_contract(broken, columns)
        except (AssertionError, KeyError):
            checks.append(f"contract_negative_{name}")
        else:
            raise AssertionError(f"Contract checker accepted {name}")
    return contract


def gate_b(checks, summary):
    contract=json.loads((ROOT/"reference/phase2-legacy-rtl-contract.json").read_text(encoding="utf-8"))
    header=(ROOT/"hardware/rtl/xp3_voice.sv").read_text(encoding="utf-8").split(");",1)[0]
    actual={}
    for direction,signed,high,name in re.findall(r"(input|output)\s+logic\s+(signed\s+)?(?:\[(\d+):0\]\s+)?(\w+)",header):
        actual[name]=dict(direction=direction,signed=bool(signed),width=int(high)+1 if high else 1)
    assert actual=={p["name"]:{k:p[k] for k in ["direction","signed","width"]} for p in contract["ports"]}
    checks.append("implemented_top_matches_all_contract_ports")
    for script in ["test_voice.py","test_voice_implementation.py"]:
        reference.p0.run([sys.executable,"-X","utf8",str(ROOT/"host"/script)],OUT/"logs"/(script+".log"))
    simulation=json.loads((OUT/"voice/summary.json").read_text(encoding="utf-8"))
    implementation=json.loads((OUT/"voice-implementation/summary.json").read_text(encoding="utf-8"))
    assert simulation["success"] and simulation["cycle_budget_passed"] and implementation["success"]
    assert simulation["cases"]==60 and simulation["frames"]==15360
    assert simulation["reset_positions"]==512 and simulation["stalls_passed"]
    assert set(simulation["negative_faults_detected"])=={"coefficient","damage_state","damage_rom","phase_error","duplicate_rom","missing_rom"}
    core=implementation["core"]
    summary.update(resources={key:core[key] for key in ["LUT","FF","DSP","BRAM18","BRAM36"]},
                   timing={key:core[key] for key in ["WNS_ns","WHS_ns","WPWS_ns"]},
                   worst_cycles=dict(single=simulation["single_cycles"],pair=simulation["pair_cycles"],scope="synthetic_nominal_rom"))
    checks.extend(["RTL_60_cases_continuous_state_no_expected_injection","RTL_full_state_output_IRQ_and_ordered_ROM",
                   "RTL_single_pair_cycles_with_state_RAM","RTL_stalls_backpressure_and_512_reset_positions",
                   "RTL_four_injected_faults_detected","complete_core_routed_resource_and_internal_timing_budget"])


def gate_c(checks, summary):
    components=["filter_tva","interpolation","voice_state","pair_filter","ramp_math","control_math","ramp_service","source_control","wave_source"]
    for name in components:
        reference.p0.run([sys.executable,"-X","utf8",str(ROOT/"host"/f"test_{name}.py")],OUT/"logs"/f"test_{name}.py.log")
    checks.append("all_numeric_components_reference_boundary_stalls_and_reset")
    reference.p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_voice_pressure.py")],OUT/"logs/test_voice_pressure.py.log")
    pressure=json.loads((OUT/"voice-pressure/summary.json").read_text(encoding="utf-8"))
    assert pressure["success"] and pressure["single_cycles"]<=44 and pressure["pair_cycles"]<=88
    checks.append("exponent_boundary_endpoint_worst_refill_cycles")
    reference.p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_voice_trace.py")],OUT/"logs/test_voice_trace.py.log")
    trace=json.loads((OUT/"voice-trace/summary.json").read_text(encoding="utf-8"))
    synthetic=json.loads((OUT/"voice/summary.json").read_text(encoding="utf-8"))
    assert trace["success"] and trace["frames"]==256000 and trace["state_words"]==51 and trace["rom_reads"]==49376
    assert trace["stages"]>0 and synthetic["stages"]>0 and trace["single_cycles"]<=44
    summary["worst_cycles"].update(single=max(summary["worst_cycles"]["single"],trace["single_cycles"],pressure["single_cycles"]),pair=max(summary["worst_cycles"]["pair"],pressure["pair_cycles"]),scope="synthetic_real_piano_and_endpoint_pressure_nominal_rom")
    checks.extend(["real_piano_256000_frames_51_state_words_and_49376_ROM_reads","integrated_interpolation_filter_TVA_stage_values_and_order","ROM_wait_0_1_7_31_and_duplicate_missing_request_detection"])
    reference.p0.run(["pwsh","-NoProfile","-File",str(ROOT/"scripts/run_gate.ps1"),"-Phase","1","-Step","D"],OUT/"logs/phase1-cumulative.log")
    for phase in [0,1]:
        previous=json.loads((ROOT/f"verification/phase-{phase:02}/summary.json").read_text(encoding="utf-8"))
        assert previous["status"]=="通过"
    checks.append("current_phase0_phase1_A_D_cumulative_regression")


def gate_d(checks, summary):
    for step in "ABC":
        evidence=json.loads((OUT/f"gate-{step}.json").read_text(encoding="utf-8"))
        assert evidence["status"]=="通过" and not evidence["failed_checks"]
    from test_voice_implementation import inspect
    assert inspect()["LUT"]==summary["resources"]["LUT"]
    for path in (ROOT/"hardware/rtl").glob("*.sv"):
        assert "SPDX-License-Identifier: GPL-3.0-only" in path.read_text(encoding="utf-8")
    assert (ROOT/"LICENSE.md").exists() and "Phase 2 handwritten RTL" in (ROOT/"THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    for directory in ["voice","voice-trace","voice-pressure","voice-implementation"]:
        assert json.loads((OUT/directory/"summary.json").read_text(encoding="utf-8"))["success"]
    assert summary["hardware_verified"] is False and summary["hardware_status"]=="NOT_TESTED_ON_HARDWARE"
    checks.extend(["A_B_C_current_evidence_consistent","GPL_RTL_and_private_ROM_evidence_boundary","resource_timing_cycle_and_hardware_scope_audit"])
    summary["status"]="通过"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", type=int, choices=[2], default=2)
    parser.add_argument("--step", choices=list("ABCD"), default="A")
    parser.add_argument("--rom-path", default="")
    args = parser.parse_args()
    if args.rom_path:
        parser.error("Import ROMs through Phase 0 before running Phase 2")
    summary = dict(schema_version=1, phase=2, status="进行中", scope="single_voice_rtl",
                   gate_status={step: "未开始" for step in "ABCD"}, hardware_verified=False,
                   hardware_status="NOT_TESTED_ON_HARDWARE", resources="UNVERIFIED",
                   timing="UNVERIFIED", worst_cycles="UNVERIFIED")
    checks = []

    def write_gate(step, status, failures):
        reference.p0.write_json(OUT / f"gate-{step}.json", dict(
            schema_version=1, phase=2, step=step, status=status, scope="single_voice_rtl",
            checks=list(checks), failed_checks=failures, hardware_verified=False))

    for step in "ABCD":
        write_gate(step, "未开始", [])
    step = "A"
    try:
        for step in "ABCD"[:"ABCD".index(args.step) + 1]:
            summary["gate_status"][step] = "进行中"
            write_gate(step, "进行中", [])
            if step == "A":
                contract = gate_a(checks)
                summary.update(state_words=len(contract["state_fields"]), golden_cases=60,
                               golden_frames=15360, trace_frames=256000, contract_negative_tests=6)
            elif step == "B":
                gate_b(checks,summary)
            elif step == "C":
                gate_c(checks,summary)
            elif step == "D":
                gate_d(checks,summary)
            summary["gate_status"][step] = "通过"
            write_gate(step, "通过", [])
            print(f"Phase 2 RTL Gate {step}: passed ({len(checks)} checks)", flush=True)
    except Exception as error:
        summary["status"] = "未通过"
        summary["gate_status"][step] = "未通过"
        write_gate(step, "未通过", [str(error)])
        raise
    finally:
        reference.p0.write_json(OUT / "summary.json", summary)
        reference.p0.write_json(ROOT / "verification/phase-02-rtl/summary.json", summary)


if __name__ == "__main__":
    main()
