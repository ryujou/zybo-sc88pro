"""Check ordered RTL sends and ping-pong mix cells against the pinned XP observer."""
import json
import re

from phase3 import ROOT, OUT as PHASE, rows, signed24
from test_filter_tva import run

OUT=PHASE/"mixer"


def vectors():
    manifest=list(rows(PHASE/"golden/manifest.csv"))
    totals=dict(cases=len(manifest),frames=0,sends=0,mix_cells=0)
    with (OUT/"vectors.txt").open("w",encoding="utf-8",newline="\n") as stream:
        def emit(*values): stream.write(" ".join(map(str,values))+"\n")
        emit(len(manifest))
        for case in manifest:
            path=PHASE/"golden"/case["case"]; count=int(case["voices"])
            emit(count,int(case["frames"]))
            state={k:int(v) for k,v in next(rows(path/"initial.csv")).items()}
            sends=iter(rows(path/"sends.csv")); mixes=iter(rows(path/"mix.csv"))
            events={}
            for event in rows(path/"events.csv"): events.setdefault(int(event["frame"]),[]).append(event)
            for post in rows(path/"expected.csv"):
                frame=int(post["frame"])
                for event in events.get(frame,[]): state[event["event"]]=int(event["value"])
                emit(frame)
                for voice in range(count):
                    emit(signed24(state[f"voice[{voice}].filterOutput_2a00"]),*[state[f"voice[{voice}].mixer_3a00[{i}]"] for i in range(4)])
                    for send in range(4):
                        r=next(sends); emit(r["slot"],r["destination"],r["contribution"]); totals["sends"]+=1
                mixed=next(mixes); seen=int(mixed["seen"])
                for cell in range(64): emit(mixed[f"cell[{cell}]"],seen>>cell&1); totals["mix_cells"]+=1
                totals["frames"]+=1
                # Observed pre-state is a component stimulus only, never an integrated scheduler input.
                state={k:int(v) for k,v in post.items()}
    return totals


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="ordered_mixer_component",hardware_verified=False)
    try:
        counts=vectors()
        run("xvlog.bat",["--sv",str(ROOT/"hardware/rtl/pcm_mixer.sv"),str(ROOT/"hardware/sim/tb_mixer.sv")],OUT)
        run("xelab.bat",["tb_mixer","-s","mixer","--debug","typical"],OUT)
        log=run("xsim.bat",["mixer","-runall"],OUT)
        match=re.search(r"MIXER_PASS frames=(\d+) sends=(\d+) cells=(\d+) reset_positions=(\d+)",log)
        assert match and "Fatal:" not in log, "Mixer comparison did not pass"
        assert [int(match[i]) for i in (1,2,3)]==[counts[k] for k in ("frames","sends","mix_cells")]
        (OUT/"positive.log").write_text(log,encoding="utf-8")
        try: negative=run("xsim.bat",["mixer","-testplusarg","damage_send","-runall"],OUT)
        except RuntimeError: negative=(OUT/"xsim.bat.log").read_text(encoding="utf-8")
        assert "MIXER_SEND_DIFFERENCE" in negative and "MIXER_PASS" not in negative
        (OUT/"negative-send.log").write_text(negative,encoding="utf-8")
        report.update(success=True,**counts,reset_positions=int(match[4]),send_fault_detected=True,limit="Mixer component only; does not prove integrated Voice scheduling, DDR deadline or DSP effect output")
        print(f"MIXER_COMPONENT_PASS frames={counts['frames']} sends={counts['sends']} cells={counts['mix_cells']}")
    except Exception as error:
        report["error"]=str(error); raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
