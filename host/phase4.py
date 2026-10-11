"""Zybo board gates; offline success never implies hardware acceptance."""
import os
import argparse
import copy
import json
import sys
from pathlib import Path

import phase0 as p0

ROOT=p0.ROOT
OUT=ROOT/"build/verification/phase-04"


def validate_contract(c):
    assert c["part"]=="xc7z010clg400-1"
    k=c["clock"];codec=c["codec"];bus=c["bus"]
    assert (k["core_hz"],k["sample_rate"],k["frame_cycles"])==(100000000,32000,3125)
    assert k["core_hz"]==k["sample_rate"]*k["frame_cycles"]
    assert k["mclk_per_frame"]==k["mclk_per_bclk"]*k["bclk_per_frame"]==384
    actual=k["board_hz"]*k["mmcm_mult_eighths"]/k["mmcm_divclk"]/k["mmcm_out_div_eighths"]
    ppm=abs(actual/k["mclk_target_hz"]-1)*1e6
    assert ppm<=k["clock_tolerance_ppm"]<=1
    assert (codec["native_bits"],codec["wire_bits"],codec["i2c_address"])==(24,16,0x1a)
    assert codec["setup"]==[[15,0],[6,0x77],[0,0x97],[1,0x97],[2,0x79],[3,0x79],[4,0x10],[5,0],[7,2],[8,0x18]]
    assert codec["vmid_wait_us"]>=75000 and codec["activate"]==[[9,1],[6,0x67]]
    assert (bus["control_base"],bus["control_bytes"],bus["block_frames"],bus["result_records_per_frame"],bus["burst_beats_max"])==(0x43c00000,4096,16,320,16)
    intervals=sorted((r["base"],r["base"]+r["bytes"],name) for name,r in c["memory"].items())
    for start,end,name in intervals:
        assert start%64==0 and end%64==0 and 0x100000<=start<end<=0x20000000,name
    assert all(a[1]<=b[0] for a,b in zip(intervals,intervals[1:]))
    assert c["memory"]["wave"]==dict(base=0x10000000,bytes=20<<20)
    for slot in ["results0","results1"]:
        assert bus["block_frames"]*bus["result_records_per_frame"]*8<=c["memory"][slot]["bytes"]
    assert c["resources"]==dict(LUT=17600,FF=35200,DSP=80,BRAM18=120)
    assert c["frames"]["voices"]==64 and c["hardware_status"]=="NOT_TESTED_ON_HARDWARE"
    assert c["midi"]["songs"]==[f"th06_{i:02}.mid" for i in range(1,8)] and c["midi"]["input_unmodified"] is True
    assert len(c["offline_required"])==len(set(c["offline_required"]))==13
    assert "real_Touhou_MIDI_controls_ROM_and_I2S_window" in c["offline_required"]
    return dict(mclk_hz=actual,sample_hz=actual/384,error_ppm=ppm)


def gate_a(checks,summary):
    previous=json.loads((ROOT/"verification/phase-03/summary.json").read_text(encoding="utf-8"))
    assert previous["status"]=="通过" and all(x=="通过" for x in previous["gate_status"].values())
    checks.append("phase3_D_entry")
    c=json.loads((ROOT/"reference/phase4-contract.json").read_text(encoding="utf-8"))
    summary["clock_plan"]=validate_contract(c)
    checks.extend(["native_cadence_and_MMCM_frequency","codec_32k_I2S16_sequence_and_mute","DDR_map_block_capacity_and_cache_ownership","64_voice_device_budget_and_effect_boundary","original_Touhou_MIDI_acceptance_inputs"])
    for name,mutate in [
        ("codec_48k",lambda x:x["codec"]["setup"][-1].__setitem__(1,0)),
        ("clock_divider",lambda x:x["clock"].update(mclk_per_frame=256)),
        ("DDR_overlap",lambda x:x["memory"]["commands"].update(base=0x10000000)),
        ("block_overflow",lambda x:x["bus"].update(block_frames=64)),
        ("voice_reduction",lambda x:x["frames"].update(voices=32)),
        ("hardware_claim",lambda x:x.update(hardware_status="PASSED")),
        ("synthetic_MIDI_substitution",lambda x:x["midi"].update(songs=["generated_piano.mid"])),
    ]:
        altered=copy.deepcopy(c);mutate(altered)
        try:validate_contract(altered)
        except AssertionError:checks.append("reject_"+name)
        else:raise AssertionError("Contract accepted "+name)
    ps=(ROOT/"hardware/board/zybo_ps7.tcl").read_text(encoding="utf-8")
    assert "SPDX-License-Identifier: MIT" in ps and "Digilent" in ps
    assert "PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF}" in ps and "PCW_DQ_WIDTH {32}" in ps
    tools=[Path(os.environ["VIVADO_ROOT"])/"bin/vivado.bat", Path(os.environ["VIVADO_ROOT"])/"bin/xsim.bat",
           Path(os.environ["VITIS_ROOT"])/"bin/xsct.bat", Path(os.environ["VITIS_ROOT"])/"gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe"]
    assert all(tool.is_file() for tool in tools)
    checks.extend(["independent_original_Zybo_preset_and_toolchain","offline_board_evidence_boundary"])


def execute(script,*arguments):
    name="-".join([script.removesuffix(".py"),*[str(arg).lstrip("-") for arg in arguments]])
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host"/script),*map(str,arguments)],OUT/"logs"/(name+".log"))


def evidence(path):
    result=json.loads((OUT/path/"summary.json").read_text(encoding="utf-8"))
    assert result["success"] and result["hardware_verified"] is False,path
    return result


def gate_b(checks,summary):
    for component in ["i2s","axi_control","block_dma","audio_bridge","commands","results","block_queue","registers","board_control"]:
        execute(f"test_{component}.py")
        path=component.replace("_","-")
        evidence(path);checks.append(component+"_simulation_or_host")
    for voices in [1,8,32,64]:
        case=f"{voices}_endpoint_q"
        execute("test_board_synth.py","--case",case,"--dma")
        result=evidence("synth-dma/"+case)
        assert result["voices"]==voices and result["max_due_cycles"]<=3125
        checks.append(case+"_DMA_ROM_state_and_I2S")
    for case in ["64_locality","64_mixer_extremes"]:
        execute("test_board_synth.py","--case",case,"--dma")
        evidence("synth-dma/"+case);checks.append(case+"_DMA_ROM_state_and_I2S")
    for song in ["th06_01","th06_05"]:
        execute("prepare_touhou_board.py","--song",song)
        execute("test_board_synth.py","--song",song,"--dma")
        result=evidence("synth-dma/"+song)
        assert result["voices"]==64 and result["frames"]==4096 and result["rom_reads"]>0
        checks.append(song+"_original_MIDI_controls_real_ROM_and_I2S_window")
    packets=[OUT/"touhou"/song/"commands.bin" for song in ["th06_01","th06_05"]]
    arguments=[argument for packet in packets for argument in ["--packet",str(packet)]]
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_board_ps.py"),*arguments],OUT/"logs/test_board_ps.log")
    ps_host=evidence("ps-host")
    assert {Path(case["packet"]) for case in ps_host["packet_cases"]}==set(packets)
    assert all(case["frames"]==4096 and case["blocks"]==256 and case["trace_negatives"]==8 and case["cache_ownership"] for case in ps_host["packet_cases"])
    assert ps_host["partial_frame_cases"]==[1,17,33] and ps_host["fault_stop"] and ps_host["ready_timeout"]
    checks.append("board_PS_real_Touhou_packets_cache_ownership_and_failure_stop")
    execute("prepare_touhou_board.py","--piano")
    execute("test_board_synth.py","--piano","--dma")
    assert evidence("synth-dma/piano")["rom_reads"]>0
    checks.append("real_piano_ROM_addressed_board_path")
    execute("test_board_implementation.py")
    summary["device"]=evidence("board")["device"]
    checks.append("complete_device_bit_XSA_STA_DRC_CDC")
    execute("build_board_ps.py")
    evidence("ps");checks.append("Cortex_A9_BSP_ELF_memory_map")
    execute("board_jtag.py","--song","th06_01")
    checks.append("independent_JTAG_offline_entry_no_connection")


def gate_c(checks,summary):
    # Offline C is cumulative software/RTL regression, never physical board acceptance.
    p0.run(["pwsh","-NoProfile","-File",str(ROOT/"scripts/run_gate.ps1"),"-Phase","3","-Step","D"],OUT/"logs/phase3-cumulative.log")
    for phase,directory in [(0,"phase-00"),(1,"phase-01"),(2,"phase-02-rtl"),(3,"phase-03")]:
        previous=json.loads((ROOT/"verification"/directory/"summary.json").read_text(encoding="utf-8"))
        assert previous["status"]=="通过",f"Phase {phase} cumulative summary failed"
        for step in "ABCD":
            gate=json.loads((ROOT/"build/verification"/directory/f"gate-{step}.json").read_text(encoding="utf-8"))
            assert gate["status"]=="通过" and not gate["failed_checks"],f"Phase {phase} Gate {step} failed"
        checks.append(f"phase{phase}_cumulative_D")
    summary["offline_C_scope"]="software_RTL_cumulative_only; physical_C_NOT_TESTED_ON_HARDWARE"


def gate_d(checks,summary):
    from test_board_implementation import inspect
    for step in "ABC":
        gate=json.loads((OUT/f"gate-{step}-offline.json").read_text(encoding="utf-8"))
        assert gate["status"]=="通过" and not gate["failed_checks"] and gate["hardware_verified"] is False,step
    assert inspect(OUT/"board")==summary["device"]
    ps=evidence("ps")
    assert ps["segments"] and all(0x00100000<=segment["address"] and segment["address"]+segment["bytes"]<=0x01000000 for segment in ps["segments"])
    for song in ["th06_01","th06_05"]:
        metadata=json.loads((OUT/"touhou"/song/"input.json").read_text(encoding="utf-8"))
        result=evidence("synth-dma/"+song)
        assert metadata["success"] and metadata["input_unmodified"] and metadata["reference_pcm_exact"]
        assert metadata["full_song_verified"] is False and result["frames"]==metadata["frames"]
        assert result["block_dma"] and result["voices"]==64 and result["wire_frames"]==result["frames"] and result["rom_reads"]>0
        assert result["max_due_cycles"]<=3125 and result["records"]==result["frames"]*320
    jtag=(OUT/"ps/jtag-check.log").read_text(encoding="utf-8")
    assert "SC88_JTAG_OFFLINE_CHECK_COMPLETE hardware_verified=0" in jtag
    contract=json.loads((ROOT/"reference/phase4-contract.json").read_text(encoding="utf-8"))
    for song in contract["midi"]["songs"]:
        with (ROOT/contract["midi"]["source"]/song).open("rb") as stream:assert stream.read(4)==b"MThd"
    notices=(ROOT/"THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    assert "Digilent" in notices and "2023" in notices and "MIT" in notices
    assert summary["hardware_verified"] is False and summary["hardware_status"]=="NOT_TESTED_ON_HARDWARE"
    checks.extend(["same_build_artifacts_and_DDR_allocations","seven_original_Touhou_inputs_and_bounded_window_scope","board_preset_and_linker_licenses","offline_delivery_never_claims_hardware_acceptance"])
    summary["offline_coverage"]={name:"通过" for name in contract["offline_required"]}
    summary["offline_status"]="通过"


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--phase",type=int,choices=[4],default=4)
    parser.add_argument("--step",choices=list("ABCD"),default="A")
    parser.add_argument("--offline",action="store_true")
    parser.add_argument("--rom-path",default="")
    args=parser.parse_args()
    if args.rom_path:parser.error("Import private ROMs through Phase 0")
    if not args.offline:parser.error("Hardware gates require connected-board evidence; use --offline for the offline work")
    summary=dict(schema_version=1,phase=4,status="进行中",scope="zybo_board_offline",offline_status="进行中",gate_status={s:"未开始" for s in "ABCD"},hardware_verified=False,hardware_status="NOT_TESTED_ON_HARDWARE")
    checks=[];step="A"
    def record(which,status,failures):
        p0.write_json(OUT/f"gate-{which}-offline.json",dict(schema_version=1,phase=4,step=which,status=status,scope="zybo_board_offline",checks=list(checks),failed_checks=failures,hardware_verified=False))
    for which in "ABCD":record(which,"未开始",[])
    try:
        for step in "ABCD"[:"ABCD".index(args.step)+1]:
            summary["gate_status"][step]="进行中"
            record(step,"进行中",[])
            if step=="A":gate_a(checks,summary)
            elif step=="B":gate_b(checks,summary)
            elif step=="C":gate_c(checks,summary)
            else:gate_d(checks,summary)
            summary["gate_status"][step]="通过";record(step,"通过",[])
            print(f"Phase 4 offline Gate {step}: passed ({len(checks)} checks)",flush=True)
    except Exception as error:
        summary["offline_status"]="未通过";summary["gate_status"][step]="未通过";record(step,"未通过",[str(error)])
        raise
    finally:
        p0.write_json(OUT/"summary.json",summary)
        p0.write_json(ROOT/"verification/phase-04/summary.json",summary)


if __name__=="__main__":main()
