"""Phase 3 gates: multi-voice golden contract, DDR access and ordered mixer boundary."""
import argparse
import copy
import csv
import json
import subprocess
import sys

import phase0 as p0

ROOT=p0.ROOT
OUT=ROOT/"build/verification/phase-03"


def rows(path):
    with path.open(encoding="utf-8",newline="") as stream:
        yield from csv.DictReader(stream)


def validate_contract(c):
    assert c["upstream_commit"]==p0.LOCK["commit"]
    assert (c["part"],c["sample_rate"],c["clock_ns"],c["frame_cycles"])==("xc7z010clg400-1",32000,10,3125)
    assert c["voice_levels"]==[1,8,32,64] and c["scheduler"]["cores"]==1
    assert c["state_contract"]=="phase2-rtl-contract.json"
    d,a,k,m=c["ddr"],c["axi"],c["cache"],c["mixer"]
    assert (d["base"],d["bytes"],d["chip_selects"],d["chip_bytes"])==(0x10000000,20<<20,5,4<<20)
    assert d["base"]+d["bytes"]<=512<<20
    assert (a["data_bits"],a["address_bits"],a["id_bits"],a["id"],a["size"],a["beats"],a["alignment_bytes"],a["outstanding_max"])==(64,32,6,0,3,4,32,4)
    assert a["burst"]=="INCR" and a["beats"]<=16
    assert a["alignment_bytes"]==a["beats"]*(a["data_bits"]//8)==k["line_bytes"]
    assert 4096%k["line_bytes"]==0
    assert (k["voices"],k["ways_per_voice"],k["data_bytes"])==(64,4,8192)
    assert k["data_bytes"]==k["voices"]*k["ways_per_voice"]*k["line_bytes"]
    assert (m["sends_per_voice"],m["destinations"],m["level_bits"],m["input_bits"],m["contribution_bits"],m["result_bits"],m["divisor"],m["banks"])==(4,64,10,24,25,24,512,2)
    assert m["send_slots"]==[0,2,2,3]
    stream=c["result_stream"]
    assert stream["data_bits"]==stream["frame_bits"]==64
    assert stream["fields"]==dict(type=[63,63],seen=[62,62],logical_slot=[61,54],voice=[53,48],send=[47,46],destination=[45,40],reserved_zero=[39,25],signed_payload=[24,0])
    assert "toward zero" in m["contribution"] and "each deposit saturates" in m["accumulate"]
    t=c["timing_envelope"]
    assert (t["ar_stall_max"],t["first_r_latency_max"],t["interbeat_gap_max"],t["output_stall_per_frame_max"],t["axi_timeout_cycles"])==(7,32,3,8,1024)
    resources=c["resources"]
    assert resources["device"]==dict(LUT=17600,FF=35200,DSP=80,BRAM18=120)
    for name,capacity in resources["device"].items():
        assert 0<resources["phase3_max"][name]<capacity
        assert resources["phase3_max"][name]+resources["phase4_reserve"][name]==capacity
    assert len(c["golden_cases"])==len(set(c["golden_cases"]))==12
    assert c["measured"]==dict(resources="UNVERIFIED",timing="UNVERIFIED",worst_cycles="UNVERIFIED",hardware="NOT_TESTED_ON_HARDWARE")


def compare_directories(left,right):
    files={p.relative_to(left) for p in left.rglob("*.csv")}
    assert files=={p.relative_to(right) for p in right.rglob("*.csv")}, "Golden file coverage differs"
    for name in sorted(files):
        assert (left/name).read_bytes()==(right/name).read_bytes(), f"Golden repeat differs: {name}"
    return len(files)


def signed24(value):
    value=int(value)&0xffffff
    return value-(1<<24) if value&0x800000 else value


def saturate24(value):
    return min(0x7fffff,max(-0x800000,value))


def audit_golden(base,c):
    manifest=list(rows(base/"manifest.csv"))
    assert {r["case"] for r in manifest}=={f"{n}_{name}" for n in c["voice_levels"] for name in c["golden_cases"]}
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    totals=dict(cases=len(manifest),frames=0,voice_frames=0,sends=0,rom_reads=0,mix_cells=0)
    sensitive=set()
    structures=set()
    for case in manifest:
        path=base/case["case"]; count=int(case["voices"]); frame_count=int(case["frames"])
        initial=next(rows(path/"initial.csv")); before={k:int(v) for k,v in initial.items()}
        expected_columns={f"voice[{voice}].{field['name']}" for voice in range(count) for field in fields}
        assert {k for k in before if k.startswith("voice[") }==expected_columns
        events={}
        for e in rows(path/"events.csv"): events.setdefault(int(e["frame"]),[]).append(e)
        sends=iter(rows(path/"sends.csv")); schedule=iter(rows(path/"schedule.csv")); mix=iter(rows(path/"mix.csv"))
        banks=[[0]*64 for _ in range(2)]
        for frame,row in enumerate(rows(path/"expected.csv")):
            after={k:int(v) for k,v in row.items()}
            assert frame<frame_count and after["sampleClock"]==before["sampleClock"]+1
            for event in events.get(frame,[]): before[event["event"]]=int(event["value"])
            voice=0
            while voice<count:
                config=before[f"voice[{voice}].filterConfig_2000"]; structure=config>>12&15
                pair=not voice%2 and voice+1<count and bool(config&16) and 1<=structure<=9
                entry=next(schedule)
                assert [int(entry[k]) for k in ("frame","voice","pair")]==[frame,voice,int(pair)]
                if pair:
                    structures.add(structure+1)
                    assert after[f"voice[{voice+1}].filterOutput_2a00"]==0
                voice+=2 if pair else 1
            bank=banks[frame%2]; seen=0; sums=[0]*64
            for voice in range(count):
                output=signed24(before[f"voice[{voice}].filterOutput_2a00"])
                new_output=signed24(after[f"voice[{voice}].filterOutput_2a00"])
                for send in range(4):
                    config=before[f"voice[{voice}].mixer_3a00[{send}]"]
                    destination=config&63; level=config>>6
                    product=output*level
                    contribution=(abs(product)//512)*(-1 if product<0 else 1)
                    entry=next(sends)
                    assert [int(entry[k]) for k in ("frame","voice","send","slot","destination","contribution")]==[frame,voice,send,voice*4+[0,2,2,3][send],destination,contribution], (case["case"],frame,voice,send)
                    if product<0 and product%512: sensitive.add("negative_truncation")
                    if output!=new_output and level: sensitive.add("prior_frame_output")
                    bit=1<<destination
                    if not seen&bit:
                        if contribution==0 and bank[destination]: sensitive.add("zero_send_clears")
                        bank[destination]=0
                    seen|=bit
                    bank[destination]=saturate24(bank[destination]+contribution)
                    sums[destination]+=contribution
                    totals["sends"]+=1
            if any(seen>>i&1 and bank[i]!=saturate24(sums[i]) for i in range(64)): sensitive.add("per_deposit_saturation")
            if any(not seen>>i&1 and bank[i] for i in range(64)): sensitive.add("unreferenced_retention")
            entry=next(mix)
            assert (int(entry["frame"]),int(entry["bank"]),int(entry["seen"]))==(frame,frame%2,seen)
            assert [int(entry[f"cell[{i}]"]) for i in range(64)]==bank, (case["case"],frame,"mixer")
            for voice in range(count):
                for field in fields:
                    value=after[f"voice[{voice}].{field['name']}"]
                    assert 0<=value<1<<field["width"], (case["case"],frame,voice,field["name"])
            totals["frames"]+=1; totals["voice_frames"]+=count; totals["mix_cells"]+=64
            before=after
        assert frame+1==frame_count
        assert next(sends,None) is None and next(schedule,None) is None and next(mix,None) is None
        read_count=0; previous=(-1,-1)
        for read in rows(path/"rom-reads.csv"):
            f,v,cs,addr,value=(int(read[k]) for k in ("frame","voice","chip_select","physical_address","value"))
            assert 0<=f<frame_count and 0<=v<count and (f,v)>=previous
            previous=(f,v)
            offset=cs*(4<<20)+addr
            expected=0 if cs>=5 or addr>=4<<20 else ((offset*73+(offset>>7)*19+0x35)^(offset>>13))&255
            assert value==expected, (case["case"],f,v,"ROM")
            read_count+=1
        assert read_count==int(case["rom_reads"])
        totals["rom_reads"]+=read_count
    assert structures==set(range(2,11))
    assert sensitive=={"negative_truncation","prior_frame_output","zero_send_clears","per_deposit_saturation","unreferenced_retention"}, sensitive
    totals["mixer_distinguishing_cases"]=sorted(sensitive)
    return totals


def gate_a(checks,summary):
    previous=json.loads((ROOT/"verification/phase-02-rtl/summary.json").read_text(encoding="utf-8"))
    assert previous["status"]=="通过" and all(s=="通过" for s in previous["gate_status"].values())
    checks.append("phase2_RTL_D_entry")
    c=json.loads((ROOT/"reference/phase3-legacy-contract.json").read_text(encoding="utf-8")); validate_contract(c)
    checks.extend(["single_core_frame_IRQ_and_config_contract","DDR_AXI3_HP0_read_subset_and_reset_contract","cache_prefetch_and_bounded_deadline_contract","ordered_sends_saturation_and_DSP_boundary_contract","device_budget_and_system_reserve"])
    mutations=[("deadline",lambda d:d.update(frame_cycles=3126)),("voice_limit",lambda d:d.update(voice_levels=[1,8,32])),("burst",lambda d:d["axi"].update(beats=32)),("contribution",lambda d:d["mixer"].update(contribution_bits=24)),("send_slot",lambda d:d["mixer"].update(send_slots=[0,1,2,3])),("resource",lambda d:d["resources"]["phase3_max"].update(LUT=17601))]
    for name,mutate in mutations:
        broken=copy.deepcopy(c); mutate(broken)
        try: validate_contract(broken)
        except AssertionError: checks.append(f"contract_reject_{name}")
        else: raise AssertionError(f"Contract accepted {name}")
    commit=subprocess.check_output(["git","-C",str(p0.UPSTREAM),"rev-parse","HEAD"],text=True).strip()
    assert commit==c["upstream_commit"]
    assert not subprocess.check_output(["git","-C",str(p0.UPSTREAM),"status","--porcelain"],text=True).strip()
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/prepare_voice_probe.py")],OUT/"logs/prepare-reference.log")
    p0.run(["cmake","-S",str(ROOT/"host/voice_reference"),"-B",str(ROOT/"build/voice-reference"),"-G","Visual Studio 17 2022","-A","x64"],OUT/"logs/configure-reference.log")
    p0.run(["cmake","--build",str(ROOT/"build/voice-reference"),"--config","Release","--target","sc88_multivoice_vectors","sc88_voice_vectors","--parallel","8"],OUT/"logs/build-reference.log")
    for directory in ["golden","golden-repeat"]:
        p0.run([str(ROOT/"build/voice-reference/Release/sc88_multivoice_vectors.exe"),str(OUT/directory)],OUT/f"logs/{directory}.log")
    files=compare_directories(OUT/"golden",OUT/"golden-repeat")
    checks.append("48_multivoice_cases_direct_repeat")
    p0.run([str(ROOT/"build/voice-reference/Release/sc88_voice_vectors.exe"),str(OUT/"phase2-observation-check")],OUT/"logs/phase2-observation-check.log")
    compare_directories(ROOT/"build/verification/phase-02-rtl/reference/golden",OUT/"phase2-observation-check")
    checks.append("phase2_60_case_observation_outputs_unchanged")
    coverage=audit_golden(OUT/"golden",c)
    coverage["repeat_csv_files"]=files
    p0.write_json(OUT/"golden-coverage.json",coverage)
    checks.extend(["all_voice_states_widths_schedule_and_clock","independent_ROM_address_data_audit","all_ordered_sends_and_64_mix_cells","five_mixer_error_distinguishing_cases"])
    summary["reference"]=coverage


def gate_b(checks,summary):
    for component in ["mixer","sample_fetcher","sample_cache","frame_fifo"]:
        p0.run([sys.executable,"-X","utf8",str(ROOT/"host"/f"test_{component}.py")],OUT/"logs"/f"test_{component}.log")
    checks.append("mixer_cache_AXI_FIFO_component_protocol_and_reset")
    summary["levels"]={}
    for voices in [1,8,32,64]:
        p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_multivoice.py"),"--voices",str(voices)],OUT/"logs"/f"voices-{voices}.log")
        numeric=json.loads((OUT/f"voices-{voices}/summary.json").read_text(encoding="utf-8"))
        assert numeric["success"] and numeric["frames"]==1536 and numeric["worst_cycles"]<=3125
        p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_multivoice_implementation.py"),"--voices",str(voices)],OUT/"logs"/f"voices-{voices}-implementation.log")
        implemented=json.loads((OUT/f"voices-{voices}-implementation/summary.json").read_text(encoding="utf-8"))
        assert implemented["success"]
        summary["levels"][str(voices)]=dict(numeric=numeric,implementation=implemented)
        checks.append(f"{voices}_voices_independent_state_ROM_sends_mix_and_routed_100MHz")
        p0.write_json(OUT/"summary.json",summary)
    summary["resources"]=summary["levels"]["64"]["implementation"]["core"]
    summary["worst_cycles"]=summary["levels"]["64"]["numeric"]["worst_cycles"]
    summary["timing"]={name:value for name,value in summary["resources"].items() if name.endswith("_ns")}


def gate_c(checks,summary):
    p0.run([sys.executable,"-X","utf8",str(ROOT/"host/test_multivoice.py"),"--voices","64","--periodic","--stress","--negative","--lifecycle"],OUT/"logs/voices-64-periodic-stress.log")
    stress=json.loads((OUT/"voices-64-stress-periodic/summary.json").read_text(encoding="utf-8"))
    assert stress["success"] and stress["periodic"] and stress["frames"]==1536
    assert stress["rom_reads"]==summary["levels"]["64"]["numeric"]["rom_reads"]
    assert stress["records"]==491520 and stress["commands"]==90112
    assert set(stress["stress"])=={"latency","gaps","mixed"}
    mixed=stress["stress"]["mixed"]
    assert (mixed["ar_stall_max"],mixed["first_r_max"],mixed["interbeat_gap_max"],mixed["output_stalls"])==(7,32,3,1536*8)
    assert stress["lifecycle"]==dict(full_fifo_frames=2,admission_deadline=3126,reset_positions=8,fresh_frames=8,underrun=1)
    assert set(stress["negative_tests"])=={"missing_voice","wrong_address","one_cycle_overrun"}
    summary["stress"]=stress
    summary["worst_cycles"]=max(summary["worst_cycles"],stress["worst_cycles"],*[p["worst_cycles"] for p in stress["stress"].values()])
    assert summary["worst_cycles"]<=3125
    checks.extend(["periodic_3125_clock_due_frames_all_51_words_and_ordered_results","measured_AR7_R32_gap3_and_output_backpressure8","full_FIFO_admission_deadline_and_preserved_committed_frames","eight_local_reset_positions_all_state_scrub_and_fresh_frames","missing_voice_wrong_address_and_one_cycle_overrun_detected"])
    summary["coverage"]=["levels_1_8_32_64_in_order","all_51_state_words","ordered_ROM_reads","ordered_sends_and_all_64_mix_cells","cold_cache_no_prewarm","max_latency_and_backpressure","simultaneous_loop_misses","random_address_updates","pair_structures_2_to_10","IRQ_first_event_only","reset_request_burst_response_output","FIFO_full_empty_and_stability","AXI_RRESP_RID_RLAST_timeout","one_missing_voice","one_wrong_address","one_cycle_overrun"]
    p0.run(["pwsh","-NoProfile","-File",str(ROOT/"scripts/run_gate.ps1"),"-Phase","2","-Step","D"],OUT/"logs/phase2-cumulative.log")
    for phase in ["00","01","02-rtl"]:
        previous=json.loads((ROOT/f"verification/phase-{phase}/summary.json").read_text(encoding="utf-8"))
        assert previous["status"]=="通过"
        for step in "ABCD":
            gate=json.loads((ROOT/f"build/verification/phase-{phase}/gate-{step}.json").read_text(encoding="utf-8"))
            assert gate["status"]=="通过" and not gate["failed_checks"]
    summary["coverage"].append("phase0_phase1_phase2_cumulative")
    checks.append("current_phase0_phase1_phase2_A_D_cumulative_regression")


def gate_d(checks,summary):
    contract=json.loads((ROOT/"reference/phase3-legacy-contract.json").read_text(encoding="utf-8"));validate_contract(contract)
    for step in "ABC":
        evidence=json.loads((OUT/f"gate-{step}.json").read_text(encoding="utf-8"))
        assert evidence["status"]=="通过" and not evidence["failed_checks"]
    assert set(summary["coverage"])==set(contract["required_rtl_tests"])
    from test_multivoice_implementation import inspect
    for voices in contract["voice_levels"]:
        level=summary["levels"][str(voices)]
        assert inspect(OUT/f"voices-{voices}-implementation")==level["implementation"]["core"]
        assert level["numeric"]["success"] and level["numeric"]["worst_cycles"]<=contract["frame_cycles"]
    for component in ["mixer","sample_fetcher","sample_cache","frame_fifo"]:
        assert json.loads((OUT/component.replace("_","-")/"summary.json").read_text(encoding="utf-8"))["success"]
    for path in (ROOT/"hardware/rtl").glob("*.sv"):
        assert "SPDX-License-Identifier: GPL-3.0-only" in path.read_text(encoding="utf-8")
    assert (ROOT/"LICENSE.md").exists() and "Phase 3" in (ROOT/"THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    assert "NOT_TESTED_ON_HARDWARE" in (ROOT/"docs/phases/phase-03.md").read_text(encoding="utf-8")
    assert summary["hardware_verified"] is False and summary["hardware_status"]=="NOT_TESTED_ON_HARDWARE"
    checks.extend(["all_required_Phase3_evidence_and_current_routed_reports","GPL_private_ROM_and_documented_hardware_boundary","64_voice_resource_timing_and_worst_deadline_audit"])
    summary["status"]="通过"


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--phase",type=int,choices=[3],default=3)
    parser.add_argument("--step",choices=list("ABCD"),default="A"); parser.add_argument("--rom-path",default="")
    args=parser.parse_args()
    if args.rom_path: parser.error("Import ROMs through Phase 0")
    summary=dict(schema_version=1,phase=3,status="进行中",scope="multi_voice_rtl",gate_status={s:"未开始" for s in "ABCD"},hardware_verified=False,hardware_status="NOT_TESTED_ON_HARDWARE",resources="UNVERIFIED",timing="UNVERIFIED",worst_cycles="UNVERIFIED")
    checks=[]
    def write_gate(step,status,failures):
        p0.write_json(OUT/f"gate-{step}.json",dict(schema_version=1,phase=3,step=step,status=status,scope="multi_voice_rtl",checks=list(checks),failed_checks=failures,hardware_verified=False))
    for step in "ABCD": write_gate(step,"未开始",[])
    step="A"
    try:
        for step in "ABCD"[:"ABCD".index(args.step)+1]:
            summary["gate_status"][step]="进行中"; write_gate(step,"进行中",[])
            if step=="A": gate_a(checks,summary)
            elif step=="B": gate_b(checks,summary)
            elif step=="C": gate_c(checks,summary)
            elif step=="D": gate_d(checks,summary)
            summary["gate_status"][step]="通过"; write_gate(step,"通过",[])
            print(f"Phase 3 Gate {step}: passed ({len(checks)} checks)",flush=True)
    except Exception as error:
        summary["status"]="未通过"; summary["gate_status"][step]="未通过"; write_gate(step,"未通过",[str(error)])
        raise
    finally:
        p0.write_json(OUT/"summary.json",summary); p0.write_json(ROOT/"verification/phase-03/summary.json",summary)


if __name__=="__main__": main()
