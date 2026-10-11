"""Offline parameter DMA, shared wave DDR and ordered multi-voice gates."""
import argparse
from collections import defaultdict
import copy
import json
import re
import struct
import sys

import phase0 as p0
import phase3 as legacy
import offline_phase1
import offline_phase2
import offline_parameter_dma as dma

ROOT = p0.ROOT
OUT = ROOT / "build/verification/offline-player/phase-03"
PUBLIC = ROOT / "verification/offline-player/phase-03"
SCOPE = "offline_parameter_multivoice_ddr_mixer_rtl"


def validate_contract(c, d):
    legacy.validate_contract(c)
    assert (c["schema_version"], c["scope"], c["top"]) == (2, SCOPE, "pcm_parameter_voice_scheduler")
    assert c["parameter_contract"] == "reference/offline-parameter-contract.json"
    assert c["parameter_dma_contract"] == "reference/offline-parameter-dma-contract.json"
    p = c["parameter_dma"]
    assert (p["region_base"], p["region_bytes"], p["alignment_bytes"], p["raw_frame_buffers"], p["raw_frame_max_bytes"], p["packet_lookahead"], p["frame_header_bytes"]) == (0x12000000, 512 << 10, 32, 2, 16384, 2, 32)
    assert p["region_base"] >= c["ddr"]["base"] + c["ddr"]["bytes"]
    assert p["region_base"] + p["region_bytes"] <= 512 << 20
    assert (d["schema_version"], d["scope"], d["magic"], d["byte_order"]) == (1, SCOPE, "SC88DMA1", "little")
    assert (d["frame_header"]["bytes"], d["frame_header"]["layout"], d["alignment_bytes"], d["max_frame_bytes"], d["frame_buffers"], d["packet_lookahead"]) == (32, "<8sQIIHHI", 32, 16384, 2, 2)
    assert d["config"]["opcode"] == 1 and d["packet"]["opcode"] == 2
    assert d["bus"] == dict(shared_with_wave=True, data_bits=64, beats=4, burst_bytes=32, outstanding_total=4, id=0, local_tag_bits=11, parameter_class_bit=10, buffer_bit=9, line_row_bits=[8, 0])
    assert d["config"]["fields"] == dict(opcode=[63,60],voice=[59,54],word=[53,48],reserved_zero=[47,32],value=[31,0])
    assert d["packet"]["fields"] == dict(opcode=[63,60],voice=[59,54],stage=[53,51],terminal_valid=[50,50],terminal_reason=[49,47],mask=[46,25],reserved_zero=[24,0])


def frame_inputs(path):
    configs, packets = defaultdict(list), defaultdict(list)
    fields = {f["name"]: f["word"] for f in dma.STATE["state_fields"]}
    for row in legacy.rows(path / "events.csv"):
        if row["event"] == "interrupt":
            continue
        match = re.fullmatch(r"voice\[(\d+)\]\.(.*)", row["event"])
        assert match, row
        configs[int(row["frame"])].append((int(match[1]), fields[match[2]], int(row["value"])))
    hooks = 0
    for row in legacy.rows(path / "parameters.csv"):
        hooks += 1
        mask, terminal = int(row["mask"]), int(row["terminal"])
        if mask or terminal != -1:
            packets[int(row["frame"])].append((int(row["voice"]), int(row["stage"]), mask, terminal, [int(row[f"value{i}"]) for i in range(22)]))
    return configs, packets, hooks


def gate_a(checks, summary):
    prerequisite = json.loads((offline_phase2.OUT / "gate-D.json").read_text(encoding="utf-8"))
    assert prerequisite["status"] == "通过" and prerequisite["scope"] == offline_phase2.SCOPE and not prerequisite["failed_checks"]
    offline_phase1.pristine()
    checks.extend(["current_parameter_phase2_D_prerequisite", "pinned_pristine_reference"])
    c = json.loads((ROOT / "reference/phase3-contract.json").read_text(encoding="utf-8"))
    d = json.loads((ROOT / "reference/offline-parameter-dma-contract.json").read_text(encoding="utf-8"))
    validate_contract(c, d)
    checks.extend(["one_core_PC_hooks_and_51_word_ownership", "shared_AXI_four_outstanding_32_byte_bursts", "two_frame_parameter_buffers_and_sparse_hook_order", "due_config_and_no_early_audio_state_advance", "3125_due_deadline_and_system_resource_reserve"])
    for name, mutate in [
        ("scope", lambda x,y: x.update(scope="multi_voice_rtl")),
        ("deadline", lambda x,y: x.update(frame_cycles=3126)),
        ("independent_parameter_bus", lambda x,y: y["bus"].update(shared_with_wave=False)),
        ("outstanding", lambda x,y: y["bus"].update(outstanding_total=8)),
        ("buffer_capacity", lambda x,y: y.update(max_frame_bytes=4096)),
        ("field_layout", lambda x,y: y["packet"]["fields"].update(mask=[45,25])),
    ]:
        bad, damaged = copy.deepcopy(c), copy.deepcopy(d)
        mutate(bad, damaged)
        try:
            validate_contract(bad, damaged)
        except AssertionError:
            checks.append("contract_rejects_" + name)
        else:
            raise AssertionError("Accepted invalid contract: " + name)
    p0.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_parameter_voice_reference.ps1")], OUT / "logs/build-parameter-reference.log")
    original = ROOT / "build/voice-reference/Release/sc88_multivoice_vectors.exe"
    parameter = ROOT / "build/parameter-voice-reference/Release/sc88_multivoice_vectors.exe"
    p0.run([str(original), str(OUT / "original-golden")], OUT / "logs/original-golden.log")
    for directory in ["golden", "golden-repeat"]:
        p0.run([str(parameter), str(OUT / directory)], OUT / "logs" / (directory + ".log"))
    files = legacy.compare_directories(OUT / "golden", OUT / "golden-repeat")
    coverage = legacy.audit_golden(OUT / "golden", c)
    hooks = packets_total = configs_total = normalized_bytes = largest = 0
    for case in legacy.rows(OUT / "golden/manifest.csv"):
        path = OUT / "golden" / case["case"]
        for filename in ["initial.csv", "expected.csv", "events.csv", "rom-reads.csv", "sends.csv", "mix.csv", "schedule.csv"]:
            assert (path / filename).read_bytes() == (OUT / "original-golden" / case["case"] / filename).read_bytes()
        configs, packets, count = frame_inputs(path)
        hooks += count
        with (path / "parameters.dma").open("wb") as stream:
            for frame in range(int(case["frames"])):
                data = dma.encode(frame, configs[frame], packets[frame])
                assert dma.decode(data, frame) == (frame, configs[frame], packets[frame])
                stream.write(data)
                largest = max(largest, len(data)); normalized_bytes += len(data)
                packets_total += len(packets[frame]); configs_total += len(configs[frame])
    checks.extend(["48_original_multi_voice_outputs_unchanged", "48_parameter_reference_direct_repeat", "all_states_ROM_ASC_schedule_and_ordered_mixer", "6144_normalized_frames_roundtrip_without_assertion_inputs"])
    good = dma.encode(3, [(0,0,1)], [(0,4,1,-1,[1]+[0]*21)])
    mutations = [
        ("magic", 0, b"X"), ("frame",8,struct.pack("<Q",4)), ("length",16,struct.pack("<I",96)),
        ("word_count",20,struct.pack("<I",4)), ("config_count",24,struct.pack("<H",2)),
        ("packet_count",26,struct.pack("<H",2)), ("flags",28,b"\x01"),
        ("cfg_reserved",36,b"\x01"), ("cfg_width",34,b"\x10"), ("cfg_opcode",39,b"\x00"),
        ("packet_reserved",40,b"\x01"), ("packet_stage",46,b"\x00"), ("packet_value_width",50,b"\x10"),
        ("odd_padding",52,b"\x01"), ("alignment_padding",56,b"\x01"),
    ]
    detected = []
    for name, offset, replacement in mutations:
        damaged = bytearray(good); damaged[offset:offset+len(replacement)] = replacement
        try:
            dma.decode(damaged, 3)
        except ValueError:
            detected.append(name)
        else:
            raise AssertionError("DMA decoder accepted " + name)
    for name, packets in [
        ("duplicate", [(0,4,1,-1,[1]+[0]*21)]*2),
        ("stage_mask", [(0,3,2,-1,[0,1]+[0]*20)]),
        ("terminal_reason", [(0,4,0,5,[0]*22)]),
        ("local_hold", [(0,4,1<<10,-1,[0]*10+[0x20000]+[0]*11)]),
        ("empty_packet", [(0,4,0,-1,[0]*22)]),
    ]:
        try:
            dma.encode(3, [], packets)
        except ValueError:
            detected.append(name)
        else:
            raise AssertionError("DMA encoder accepted " + name)
    checks.append("20_DMA_format_negative_checks")
    coverage.update(hooks=hooks,sparse_packets=packets_total,configs=configs_total,normalized_bytes=normalized_bytes,largest_frame_bytes=largest,repeat_csv_files=files,format_negatives=detected)
    p0.write_json(OUT / "golden-coverage.json", coverage)
    summary["reference"] = coverage
    p0.run(["cmake","--build",str(ROOT/"build/offline-player"),"--config","Release","--target","sc88_parameter_replay","--parallel","8"],OUT/"logs/build-peak-scanner.log")
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/prepare_parameter_peaks.py")],OUT/"logs/parameter-peaks.log")
    peaks=json.loads((OUT/"parameter-peaks/summary.json").read_text(encoding="utf-8"))
    assert peaks["success"] and peaks["seven_songs_rescanned"]
    assert [p["original_peak_bytes"] for p in peaks["sources"]]==[2322,21174,262568]
    summary["parameter_peaks"]=peaks
    checks.append("seven_actual_song_peak_frame_window_block_transport_fixtures")


def inspect_b(checks,summary):
    source=(ROOT/"hardware/rtl/pcm_parameter_voice_scheduler.sv").read_text(encoding="utf-8")
    for declaration in ["input logic parameter_desc_valid","output logic parameter_desc_ready","input logic [63:0] parameter_desc_frame","input logic [31:0] parameter_desc_address","input logic [14:0] parameter_desc_bytes"]:
        assert declaration in source,declaration
    assert "xp3_parameter_voice voice_core" in source and "pcm_sample_fetcher #(.TAG_BITS(11))" in source
    assert all(unit not in source for unit in ["xp3_ramp_math","xp3_control_math","xp3_ramp_service","xp3_source_control"])
    checks.append("current_descriptor_ports_and_single_shared_parameter_core")
    for component in ["mixer","sample-fetcher","sample-cache","frame-fifo","parameter-dma"]:
        result=json.loads((OUT/component/"summary.json").read_text(encoding="utf-8"))
        assert result["success"] and not result["hardware_verified"]
    transport=json.loads((OUT/"parameter-dma/summary.json").read_text(encoding="utf-8"))
    assert transport["fields"]==22 and transport["actual_peak_frames"]==273 and len(transport["negative_cases"])==21
    checks.extend(["five_current_AXI_cache_mixer_FIFO_parameter_components", "22_PC_fields_and_273_actual_peak_frames_in_RTL_DMA"])
    from test_parameter_multivoice_implementation import inspect
    summary["levels"]={}
    for voices in [1,8,32,64]:
        result=json.loads((OUT/f"voices-{voices}/summary.json").read_text(encoding="utf-8"))
        assert result["success"] and result["scope"]==SCOPE and result["voices"]==voices and result["frames"]==1536 and result["cases"]==12
        assert result["worst_cycles"]<=3125 and result["DMA_traffic"]["parameter_reads"]>0
        implementation=json.loads((OUT/f"voices-{voices}-implementation/summary.json").read_text(encoding="utf-8"))
        assert implementation["success"] and implementation["scope"]==SCOPE and implementation["core"]==inspect(OUT/f"voices-{voices}-implementation")
        summary["levels"][str(voices)]=dict(numerical=result,implementation=implementation)
        checks.extend([f"{voices}_voice_states_ROM_sends_mix_with_actual_parameter_DMA",f"{voices}_voice_complete_integrated_route_resource_and_timing"])
    summary["resources"]=summary["levels"]["64"]["implementation"]["core"]
    summary["timing"]={key:value for key,value in summary["resources"].items() if key.endswith("_ns")}
    summary["worst_cycles"]=summary["levels"]["64"]["numerical"]["worst_cycles"]


def gate_b(checks,summary):
    for component in ["mixer","sample_fetcher","sample_cache","frame_fifo"]:
        directory=component.replace("_","-")
        code=f"import sys;sys.path.insert(0,{str(ROOT/'host')!r});from pathlib import Path;import test_{component} as t;t.OUT=Path({str(OUT/directory)!r});t.main()"
        p0.run([sys.executable,"-X","utf8","-c",code],OUT/"logs"/(directory+".log"))
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_parameter_dma.py")],OUT/"logs/parameter-dma.log")
    for voices in [1,8,32,64]:
        p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_parameter_multivoice.py"),"--voices",str(voices)],OUT/"logs"/f"voices-{voices}.log")
        result=json.loads((OUT/f"voices-{voices}/summary.json").read_text(encoding="utf-8"))
        assert result["success"] and result["worst_cycles"]<=3125
        p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_parameter_multivoice_implementation.py"),"--voices",str(voices)],OUT/"logs"/f"voices-{voices}-implementation.log")
    inspect_b(checks,summary)


def inspect_c(checks,summary):
    result=json.loads((OUT/"voices-64-stress-periodic/summary.json").read_text(encoding="utf-8"))
    assert result["success"] and result["periodic"] and result["frames"]==1536 and set(result["stress"])=={"latency","gaps","mixed"}
    assert all(profile["worst_cycles"]<=3125 for profile in result["stress"].values())
    assert result["lifecycle"]["full_fifo_frames"]==2 and result["lifecycle"]["admission_deadline"]==3126 and result["lifecycle"]["reset_positions"]>=14
    assert set(result["negative_tests"])>={"missing_voice","wrong_address","one_cycle_overrun","parameter_coefficient","missing_parameters","late_parameters"}
    assert result["stress"]["mixed"]["DMA_traffic"]["contentions"]>0
    previous=json.loads((offline_phase2.OUT/"summary.json").read_text(encoding="utf-8"))
    assert previous["status"]=="通过" and previous["scope"]==offline_phase2.SCOPE and all(v=="通过" for v in previous["gate_status"].values())
    p1=json.loads((offline_phase1.OUT/"summary.json").read_text(encoding="utf-8"))
    assert p1["status"]=="通过" and p1["scope"]==offline_phase1.SCOPE
    p0_current=json.loads((ROOT/"build/verification/phase-00/gate-D.json").read_text(encoding="utf-8"))
    assert p0_current["status"]=="通过" and p0_current["scope"]=="software"
    checks.extend(["64_voice_continuous_parameter_wave_shared_DDR_pressure", "due_deadline_backpressure_fault_and_parameter_reset_lifecycle", "integrated_missing_late_coefficient_address_voice_and_one_cycle_negatives", "current_parameter_Phase0_1_2_cumulative_regression"])
    summary["continuous_pressure"]=result
    summary["worst_cycles"]=max(summary["worst_cycles"],*(r["worst_cycles"] for r in result["stress"].values()))


def gate_c(checks,summary):
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_parameter_multivoice.py"),"--voices","64","--periodic","--stress","--negative","--lifecycle"],OUT/"logs/64-continuous-pressure.log")
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/offline_phase2.py"),"--step","D"],OUT/"logs/current-Phase0-2-cumulative.log")
    inspect_c(checks,summary)


def gate_d(checks,summary):
    offline_phase1.pristine()
    c=json.loads((ROOT/"reference/phase3-contract.json").read_text(encoding="utf-8"));d=json.loads((ROOT/"reference/offline-parameter-dma-contract.json").read_text(encoding="utf-8"));validate_contract(c,d)
    for step in "ABC":
        gate=json.loads((OUT/f"gate-{step}.json").read_text(encoding="utf-8"))
        assert gate["scope"]==SCOPE and gate["status"]=="通过" and not gate["failed_checks"]
    assert summary["worst_cycles"]<=3125 and not summary["hardware_verified"]
    assert "Offline parameter Phase 3" in (ROOT/"THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    assert not list((ROOT/"verification/offline-player/phase-03").rglob("*.scp"))
    checks.extend(["current_interfaces_resources_route_deadline_proofs_complete", "GPL_private_data_and_pristine_reference", "offline_OOC_scope_and_hardware_status_truthful"])
    summary["status"]="通过"


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--step", choices=list("ABCD"), default="A")
    parser.add_argument("--phase",type=int,default=3); parser.add_argument("--rom-path",default=""); parser.add_argument("--offline",action="store_true")
    args = parser.parse_args()
    checks = []
    summary = dict(schema_version=2,phase=3,status="进行中",scope=SCOPE,gate_status={s:"未开始" for s in "ABCD"},hardware_verified=False,hardware_status="NOT_TESTED_ON_HARDWARE",resources="UNVERIFIED",timing="UNVERIFIED",worst_cycles="UNVERIFIED")
    def write(step, status, failed=None):
        p0.write_json(OUT / f"gate-{step}.json", dict(schema_version=2,phase=3,step=step,status=status,scope=SCOPE,checks=list(checks),failed_checks=failed or [],hardware_verified=False))
        summary["gate_status"][step] = status
        p0.write_json(OUT / "summary.json", summary); p0.write_json(PUBLIC / "summary.json", summary)
    for step in "ABCD":
        write(step, "未开始")
    for step in "ABCD"[:"ABCD".index(args.step)+1]:
        try:
            {"A":gate_a,"B":gate_b,"C":gate_c,"D":gate_d}[step](checks,summary)
            write(step, "通过")
        except Exception as error:
            summary["status"] = "失败"; write(step, "失败", [str(error)]); raise


if __name__ == "__main__": main()
