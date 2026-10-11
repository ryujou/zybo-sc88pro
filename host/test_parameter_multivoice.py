"""Continuous integrated Voice/DDR/mixer checks, one admitted voice level at a time."""
import argparse
from collections import defaultdict
import json
import re
import shutil

from offline_phase3 import ROOT,OUT as PHASE,frame_inputs
from phase3 import rows
import offline_parameter_dma as dma
from test_parameter_voice import RTL
from test_filter_tva import run


def vectors(out,voices):
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    field_words={f["name"]:f["word"] for f in fields}
    manifest=[r for r in rows(PHASE/"golden/manifest.csv") if int(r["voices"])==voices]
    totals=dict(cases=len(manifest),frames=0,rom_reads=0,records=0,commands=0)
    seed=next(rows(PHASE/"golden/1_locality/initial.csv"))
    seed_words=[(field["word"],int(seed["voice[0]."+field["name"]])) for field in fields]
    seed_words=[(word,2 if word==49 else value) for word,value in seed_words]
    (out/"lifecycle-initial.txt").write_text("\n".join(f"{word} {value}" for word,value in seed_words)+"\n",encoding="utf-8")
    _,seed_packets,_=frame_inputs(PHASE/"golden/1_locality")
    seed_dma=dma.encode(0,[(0,2,int(seed["voice[0].sampleLoop_0200"]))],seed_packets[1])
    (out/"lifecycle-parameters.mem").write_text("\n".join(f"{byte:02x}" for byte in seed_dma)+"\n",encoding="utf-8")
    assert len(seed_dma)==64
    with (out/"vectors.txt").open("w",encoding="utf-8",newline="\n") as stream:
        def emit(*items): stream.write(" ".join(map(str,items))+"\n")
        for case in manifest:
            path=PHASE/"golden"/case["case"]; initial=next(rows(path/"initial.csv"))
            descriptors=sum(int(initial[f"waveRomConfig[{i}]"])<<(8*i) for i in range(8))
            emit(0,initial["irqStatus"],initial["irqConfigMask"],initial["interrupt"],descriptors)
            for voice in range(voices):
                for field in fields: emit(1,voice,field["word"],initial[f"voice[{voice}].{field['name']}"])
            events=defaultdict(list);reads=defaultdict(list);sends=defaultdict(list);commands=defaultdict(list)
            configs, packets, _ = frame_inputs(path)
            memory=bytearray(); descriptors_list=[]
            for frame in range(int(case['frames'])):
                data=dma.encode(frame,configs[frame],packets[frame])
                descriptors_list.append((0x12000000+len(memory),len(data)));memory.extend(data)
            assert len(memory)<=512<<10
            memory_file=out/(case['case']+'.mem')
            memory_file.write_text('\n'.join(f'{byte:02x}' for byte in memory)+'\n',encoding='utf-8')
            emit(9,case['frames'],memory_file.name)
            for address,size in descriptors_list: emit(address,size)
            for r in rows(path/"events.csv"):
                if r['event']=='interrupt': events[int(r['frame'])].append(r)
            for r in rows(path/"rom-reads.csv"): reads[int(r["frame"])].append(r)
            for r in rows(path/"sends.csv"): sends[int(r["frame"])].append(r)
            for r in rows(path/"schedule.csv"): commands[int(r["frame"])].append(r)
            mixes=iter(rows(path/"mix.csv"))
            for post in rows(path/"expected.csv"):
                frame=int(post["frame"])
                for event in events[frame]:
                    key=event["event"]
                    if key.startswith("voice["):
                        match=re.fullmatch(r"voice\[(\d+)\]\.(.*)",key)
                        emit(1,int(match[1]),field_words[match[2]],event["value"])
                    elif key=="interrupt": emit(4,event["value"])
                    else: raise AssertionError(f"Unimplemented external event: {key}")
                emit(2,frame,voices-1,post["irqStatus"],post["interrupt"],post["irqBlockedEvent"],len(reads[frame]),voices*4+64,len(commands[frame]))
                for read in reads[frame]: emit(read["voice"],read["chip_select"],read["physical_address"],read["value"])
                for command in commands[frame]: emit(command["voice"],command["pair"])
                for send in sends[frame]:
                    word=(int(send["slot"])<<54)|(int(send["voice"])<<48)|(int(send["send"])<<46)|(int(send["destination"])<<40)|(int(send["contribution"])&0x1ffffff)
                    emit(f"{word:016x}")
                mix=next(mixes);seen=int(mix["seen"])
                for cell in range(64): emit(f"{((1<<63)|((seen>>cell&1)<<62)|(cell<<40)|(int(mix[f'cell[{cell}]'])&0x1ffffff)):016x}")
                for voice in range(voices):
                    for field in fields: emit(3,voice,field["word"],post[f"voice[{voice}].{field['name']}"])
                totals["frames"]+=1;totals["rom_reads"]+=len(reads[frame]);totals["records"]+=voices*4+64;totals["commands"]+=len(commands[frame])
    return totals


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--voices",type=int,choices=[1,8,32,64],required=True);parser.add_argument("--negative",action="store_true");parser.add_argument("--stress",action="store_true");parser.add_argument("--periodic",action="store_true")
    parser.add_argument("--lifecycle",action="store_true")
    args=parser.parse_args();out=PHASE/(f"voices-{args.voices}"+("-stress" if args.stress else "")+("-periodic" if args.periodic else ""));out.mkdir(parents=True,exist_ok=True)
    simulation=["multivoice"]+(["-testplusarg","periodic","-testplusarg","parameter_competition"] if args.periodic else [])
    report=dict(success=False,scope="offline_parameter_multivoice_ddr_mixer_rtl",voices=args.voices,periodic=args.periodic,hardware_verified=False)
    try:
        counts=vectors(out,args.voices)
        for table in ["xp3_interpolation.mem"]: shutil.copyfile(ROOT/"hardware/rtl"/table,out/table)
        sources=RTL+["pcm_mixer","pcm_frame_fifo","pcm_sample_fetcher","pcm_sample_cache","pcm_parameter_dma","pcm_parameter_voice_scheduler"]
        wrapper=out/"level_tb.sv"
        wrapper.write_text(f"module level_tb; tb_parameter_multivoice #(.VOICE_LIMIT({args.voices})) test(); endmodule\n",encoding="utf-8")
        run("xvlog.bat",["--sv",*[str(ROOT/"hardware/rtl"/(name+".sv")) for name in sources],str(ROOT/"hardware/sim/tb_parameter_multivoice.sv"),str(wrapper)],out)
        run("xelab.bat",["level_tb","-s","multivoice","--debug","typical"],out)
        log=run("xsim.bat",[*simulation,"-runall"],out)
        (out/"positive.log").write_text(log,encoding="utf-8")
        match=re.search(r"MULTIVOICE_PASS cases=(\d+) frames=(\d+) reads=(\d+) records=(\d+) worst_cycles=(\d+)",log)
        assert match and "Fatal:" not in log, "Integrated numerical/protocol comparison did not pass"
        assert [int(match[i]) for i in (1,2,3,4)]==[counts[k] for k in ("cases","frames","rom_reads","records")]
        assert int(match[5])<=3125
        traffic=re.search(r"PARAMETER_MULTIVOICE_DMA parameter_reads=(\d+) wave_reads=(\d+) contentions=(\d+)",log)
        assert traffic and int(traffic[1])>0
        report['DMA_traffic']=dict(parameter_reads=int(traffic[1]),wave_reads=int(traffic[2]),contentions=int(traffic[3]))
        if args.periodic: assert f"MULTIVOICE_PERIODIC frames={counts['frames']} period=3125" in log
        if args.stress:
            report["stress"]={}
            for profile in ["latency","gaps","mixed"]:
                pressure=run("xsim.bat",[*simulation,"-testplusarg",f"stress_{profile}","-runall"],out)
                (out/f"stress-{profile}.log").write_text(pressure,encoding="utf-8")
                result=re.search(r"MULTIVOICE_PASS cases=(\d+) frames=(\d+) reads=(\d+) records=(\d+) worst_cycles=(\d+)",pressure)
                bus=re.search(r"MULTIVOICE_BUS ar_stall_max=(\d+) first_r_max=(\d+) interbeat_gap_max=(\d+) output_stalls=(\d+)",pressure)
                assert result and bus and "Fatal:" not in pressure, f"Integrated pressure profile failed: {profile}"
                assert [int(result[i]) for i in (1,2,3,4)]==[counts[k] for k in ("cases","frames","rom_reads","records")]
                assert int(result[5])<=3125
                if args.periodic: assert f"MULTIVOICE_PERIODIC frames={counts['frames']} period=3125" in pressure
                measured=dict(zip(["ar_stall_max","first_r_max","interbeat_gap_max","output_stalls"],map(int,bus.groups())))
                assert measured["ar_stall_max"]==7 and measured["first_r_max"]<=32 and measured["interbeat_gap_max"]<=3
                assert measured["output_stalls"]==counts["frames"]*8
                assert measured["first_r_max"]==32 if profile=="latency" else measured["interbeat_gap_max"]==3
                if profile=="mixed": assert measured["first_r_max"]==32
                traffic=re.search(r"PARAMETER_MULTIVOICE_DMA parameter_reads=(\d+) wave_reads=(\d+) contentions=(\d+)",pressure)
                assert traffic and int(traffic[1])>0
                report["stress"][profile]=dict(worst_cycles=int(result[5]),**measured,DMA_traffic=dict(parameter_reads=int(traffic[1]),wave_reads=int(traffic[2]),contentions=int(traffic[3])))
        if args.lifecycle:
            recovery=run("xsim.bat",["multivoice","-testplusarg","recovery","-runall"],out)
            (out/"recovery.log").write_text(recovery,encoding="utf-8")
            assert "MULTIVOICE_RECOVERY_PASS timeout_drain_and_fresh_frame=1" in recovery and "Fatal:" not in recovery
            lifecycle=run("xsim.bat",["multivoice","-testplusarg","lifecycle","-runall"],out)
            (out/"lifecycle.log").write_text(lifecycle,encoding="utf-8")
            assert "MULTIVOICE_LIFECYCLE_PASS full_fifo_frames=2 admission_deadline=3126 reset_positions=8 fresh_frames=8 underrun=1" in lifecycle and "Fatal:" not in lifecycle
            parameter_lifecycle=run("xsim.bat",["multivoice","-testplusarg","parameter_lifecycle","-runall"],out)
            (out/"parameter-lifecycle.log").write_text(parameter_lifecycle,encoding="utf-8")
            assert "PARAMETER_LIFECYCLE_PASS reset_positions=6 fresh_frames=6" in parameter_lifecycle and "Fatal:" not in parameter_lifecycle
            report["lifecycle"]=dict(full_fifo_frames=2,admission_deadline=3126,reset_positions=14,parameter_reset_positions=6,fresh_frames=14,underrun=1,timeout_drain=True)
        if args.negative:
            negatives=[("missing_voice","FRAME_COMMAND_COUNT_DIFFERENCE" if args.voices==1 else "VOICE_COMMAND_DIFFERENCE"),("wrong_address","ROM byte mismatch"),("one_cycle_overrun","ONE_CYCLE_OVERRUN_DETECTED elapsed=3126"),("parameter_coefficient","VOICE_STATE_DIFFERENCE"),("missing_parameters","MISSING_PARAMETERS_DEADLINE_DETECTED elapsed=3126"),("late_parameters","LATE_PARAMETERS_DEADLINE_DETECTED elapsed=3126")]
            for fault,marker in negatives:
                try: negative=run("xsim.bat",[*simulation,"-testplusarg",fault,"-runall"],out)
                except RuntimeError: negative=(out/"xsim.bat.log").read_text(encoding="utf-8")
                (out/f"negative-{fault}.log").write_text(negative,encoding="utf-8")
                assert marker in negative and "MULTIVOICE_PASS" not in negative, fault
            report["negative_tests"]=[name for name,_ in negatives]
        report.update(success=True,**counts,worst_cycles=int(match[5]),limit="Simulation evidence; PS/DDR hardware latency and board timing remain unverified")
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally: (out/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
