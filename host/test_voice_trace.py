"""Real piano RTL progression; initial state and inter-step external events are the only state inputs."""
import json
import re
import shutil
from collections import defaultdict
from test_filter_tva import ROOT, REFERENCE, rows, run
from test_voice import RTL

OUT=ROOT/"build/verification/phase-02-rtl/voice-trace"

def vectors(parameter_hooks=None):
    directory=REFERENCE/"trace-piano"
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    initial=next(rows(directory/"voice-initial.csv"))
    assert int(initial["voice[63].filterOutput_2a00"])==0
    controls=defaultdict(list);reads=defaultdict(list);samples={};stages=defaultdict(list)
    for event in rows(directory/"voice-controls.csv"): controls[int(event["frame"])].append(event)
    for read in rows(directory/"voice-rom-reads.csv"):
        assert read["voice"]=="1"
        reads[int(read["frame"])].append(read)
    for stage in rows(directory/"voice-stages.csv"):
        assert stage["voice"]=="1"
        if stage["stage"]=="interpolation": samples[int(stage["frame"])]=int(stage["b"])
        else: stages[int(stage["frame"])].append(stage)
    clock=int(initial["sampleClock"]);count=0
    hooks=parameter_hooks(directory) if parameter_hooks else None
    with (OUT/"vectors.txt").open("w",encoding="utf-8",newline="\n") as out:
        def emit(*items):out.write(" ".join(map(str,items))+"\n")
        descriptors=sum(int(initial[f"waveRomConfig[{i}]"])<<(8*i) for i in range(8))
        emit(0,initial["irqStatus"],initial["irqConfigMask"],initial["interrupt"],descriptors,31)
        for field in fields:emit(1,63,field["word"],initial[f"voice[63].{field['name']}"])
        for expected in rows(directory/"voice-expected.csv"):
            assert int(expected["frame"])==clock and int(expected["sampleClock"])==clock+1
            for field in fields:
                assert expected[f"voice[62].{field['name']}"]==initial[f"voice[62].{field['name']}"]
            for event in controls.pop(clock,[]):
                name,value=event["event"],int(event["value"])
                if name.startswith("voice[63]."):
                    field=next(f for f in fields if f["name"]==name[10:]);emit(1,63,field["word"],value)
                else:
                    assert name=="interrupt" and value==0, event
                    emit(4,0)
            emit(8,len(stages[clock]))
            for stage in stages.pop(clock):emit(int(stage["stage"]=="tva"),63,*[stage[key] for key in "abcdefgh"])
            if hooks is not None:
                packets=hooks.pop(clock,[])
                emit(9,len(packets))
                for packet in packets:emit(clock,*packet)
            emit(2,clock,0,expected["irqStatus"],expected["interrupt"],expected["irqBlockedEvent"],int(clock in samples),samples.pop(clock,0),0,expected["voice[63].filterOutput_2a00"],0,len(reads[clock]))
            for read in reads.pop(clock):emit(read["chip_select"],read["physical_address"],0,read["value"])
            for field in fields:emit(3,63,field["word"],expected[f"voice[63].{field['name']}"])
            clock+=1;count+=1
    assert not controls and not reads and not samples and not stages and count==256000
    assert not hooks, "Unconsumed PC parameter hooks"
    return count

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(scope="continuous_voice_real_piano",success=False,hardware_verified=False)
    try:
        count=vectors()
        for table in ["xp3_pitch.mem","xp3_interpolation.mem"]:shutil.copyfile(ROOT/"hardware/rtl"/table,OUT/table)
        shutil.copyfile(REFERENCE/"trace-piano/decoded-wave.bin",OUT/"decoded-wave.bin")
        run("xvlog.bat",["--sv",*[str(ROOT/"hardware/rtl"/(name+".sv")) for name in RTL],str(ROOT/"hardware/sim/tb_voice.sv")],OUT)
        run("xelab.bat",["tb_voice","-s","voice","--debug","typical"],OUT)
        log=run("xsim.bat",["voice","-runall","-testplusarg","trace"],OUT)
        (OUT/"nominal.log").write_text(log,encoding="utf-8")
        match=re.search(r"VOICE_SYNTHETIC_PASS cases=1 frames=(\d+) single_cycles=(\d+) pair_cycles=0",log)
        assert match and int(match[1])==count and "Fatal:" not in log
        assert int(match[2])<=44, "Real piano exceeds single Voice cycle budget"
        stage_match=re.search(r"VOICE_STAGES_PASS count=(\d+)",log)
        assert stage_match and int(stage_match[1])>0
        report.update(success=True,stages=int(stage_match[1]),frames=count,voice=63,state_words=51,single_cycles=int(match[2]),rom_reads=49376,rom_source="Pinned descrambler output; address-indexed bytes independent of expected results")
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally:(OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")

if __name__=="__main__":main()
