"""Continuous RTL Voice state progression from initial state and explicit external events."""
import json
import re
import shutil
from collections import defaultdict
from test_filter_tva import ROOT, REFERENCE, rows, run

OUT=ROOT / "build/verification/phase-02-rtl/voice"
RTL=["xp3_sample_pkg", "xp3_voice_state", "xp3_interpolate", "xp3_wave_source", "xp3_ramp_math", "xp3_control_math", "xp3_source_control", "xp3_ramp_service", "xp3_filter_tva", "xp3_pair_filter", "xp3_voice"]

def vectors(base=REFERENCE/"golden", names=None, parameter_hooks=None):
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    if names is None: names=json.loads((ROOT/"reference/phase2-contract.json").read_text(encoding="utf-8"))["cases"]
    with (OUT/"vectors.txt").open("w",encoding="utf-8",newline="\n") as out:
        def emit(*items): out.write(" ".join(map(str,items))+"\n")
        for name in names:
            directory=base/name
            initial=next(rows(directory/"initial.csv"))
            paired=name.startswith("pair_structure_") or "_pair_" in name
            descriptors=sum(int(initial[f"waveRomConfig[{i}]"])<<(8*i) for i in range(8))
            emit(0,initial["irqStatus"],initial["irqConfigMask"],initial["interrupt"],descriptors,0 if name=="physical_bus8" else 1)
            for voice in range(2 if paired else 1):
                for field in fields: emit(1,voice,field["word"],initial[f"voice[{voice}].{field['name']}"])
            events=defaultdict(list);reads=defaultdict(list);samples=defaultdict(dict);stages=defaultdict(list)
            for row in rows(directory/"events.csv"): events[int(row["frame"])].append(row)
            for row in rows(directory/"rom-reads.csv"): reads[int(row["frame"])].append(row)
            for row in rows(directory/"stages.csv"):
                if row["stage"]=="interpolation": samples[int(row["frame"])][int(row["voice"])]=int(row["b"])
                else: stages[int(row["frame"])].append(row)
            clock=int(initial["sampleClock"])
            hooks=parameter_hooks(directory) if parameter_hooks else None
            for expected in rows(directory/"expected.csv"):
                frame=int(expected["frame"])
                for event in events[frame]:
                    key,value=event["event"],int(event["value"])
                    if key.startswith("voice[0]."):
                        field=next(f for f in fields if f["name"]==key[9:]);emit(1,0,field["word"],value)
                    else:
                        emit({"hostRead":4,"releaseMask":5,"commitRelease":6,"powerReset":7}[key],value)
                        if key=="powerReset": clock=0
                output=lambda v:int(expected[f"voice[{v}].filterOutput_2a00"])
                emit(8,len(stages[frame]))
                for stage in stages[frame]:emit(int(stage["stage"]=="tva"),stage["voice"],*[stage[key] for key in "abcdefgh"])
                if hooks is not None:
                    packets=hooks.pop(frame,[])
                    emit(9,len(packets))
                    for packet in packets:emit(clock,*packet)
                emit(2,clock,int(paired),expected["irqStatus"],expected["interrupt"],expected["irqBlockedEvent"],sum(1<<v for v in samples[frame]),samples[frame].get(0,0),samples[frame].get(1,0),output(0),output(1) if paired else 0,len(reads[frame]))
                for read in reads[frame]: emit(read["chip_select"],read["physical_address"],read["voice"],read["value"])
                for voice in range(2 if paired else 1):
                    for field in fields: emit(3,voice,field["word"],expected[f"voice[{voice}].{field['name']}"])
                clock+=1
            assert not hooks, "Unconsumed PC parameter hooks"
    return len(names)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(scope="continuous_voice_synthetic",success=False,hardware_verified=False)
    try:
        count=vectors()
        for name in ["xp3_pitch.mem","xp3_interpolation.mem"]: shutil.copyfile(ROOT/"hardware/rtl"/name,OUT/name)
        run("xvlog.bat",["--sv",*[str(ROOT/"hardware/rtl"/(name+".sv")) for name in RTL],str(ROOT/"hardware/sim/tb_voice.sv")],OUT)
        run("xelab.bat",["tb_voice","-s","voice","--debug","typical"],OUT)
        log=run("xsim.bat",["voice","-runall"],OUT)
        (OUT/"nominal.log").write_text(log,encoding="utf-8")
        match=re.search(r"VOICE_SYNTHETIC_PASS cases=(\d+) frames=(\d+) single_cycles=(\d+) pair_cycles=(\d+)",log)
        assert "VOICE_RESET_PASS checks=512" in log and "VOICE_CONFIG_PASS" in log
        assert match and int(match[1])==count and int(match[2])==count*256 and "Fatal:" not in log
        stage_match=re.search(r"VOICE_STAGES_PASS count=(\d+)",log)
        assert stage_match and int(stage_match[1])>0
        report.update(success=True,stages=int(stage_match[1]),cases=count,frames=int(match[2]),single_cycles=int(match[3]),pair_cycles=int(match[4]),cycle_budget_passed=int(match[3])<=44 and int(match[4])<=88)
        assert report["cycle_budget_passed"], "Full Voice cycle budget exceeded"
        stalled=run("xsim.bat",["voice","-runall","-testplusarg","stalls"],OUT)
        (OUT/"stalls.log").write_text(stalled,encoding="utf-8")
        stalled_match=re.search(r"VOICE_SYNTHETIC_PASS cases=(\d+) frames=(\d+) single_cycles=(\d+) pair_cycles=(\d+)",stalled)
        assert stalled_match and int(stalled_match[2])==count*256 and "Fatal:" not in stalled
        assert "VOICE_RESET_PASS checks=512" in stalled
        report.update(reset_positions=512,stalls_passed=True,stalled_single_cycles=int(stalled_match[3]),stalled_pair_cycles=int(stalled_match[4]))
        negatives=[]
        for fault in ["damage_rom","damage_state","phase_error","coefficient","duplicate_rom","missing_rom"]:
            if fault=="coefficient":
                table=(OUT/"xp3_interpolation.mem").read_text(encoding="utf-8").splitlines()
                table[0]=format(int(table[0],16)^1,"x")
                (OUT/"xp3_interpolation.mem").write_text("\n".join(table)+"\n",encoding="utf-8")
            try:
                negative=run("xsim.bat",["voice","-runall","-testplusarg",fault],OUT)
            except RuntimeError:
                negative=(OUT/"xsim.bat.log").read_text(encoding="utf-8")
            finally:
                if fault=="coefficient": shutil.copyfile(ROOT/"hardware/rtl/xp3_interpolation.mem",OUT/"xp3_interpolation.mem")
            (OUT/f"negative-{fault}.log").write_text(negative,encoding="utf-8")
            assert "VOICE_SYNTHETIC_PASS" not in negative and ("VOICE_STATE_DIFFERENCE" in negative or "VOICE_RESULT_DIFFERENCE" in negative or "VOICE_STAGE_INPUT" in negative or "VOICE_FILTER_STAGE" in negative or "VOICE_ROM_DIFFERENCE" in negative or "Unexpected ROM transaction" in negative), fault
            negatives.append(fault)
        report["negative_faults_detected"]=negatives
        print(json.dumps(report))
    except Exception as error:
        report["success"]=False;report["error"]=str(error);raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")

if __name__=="__main__": main()
