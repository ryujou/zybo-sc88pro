"""Implement the current admitted Voice level with cache, AXI and complete-frame output."""
import argparse
import json

from phase3 import ROOT,OUT as PHASE
from test_filter_tva import run
from test_voice_units_implementation import inspect_reports


def inspect(out):
    core=inspect_reports(["pcm_voice_scheduler"],out)["pcm_voice_scheduler"]
    assert core["LUT"]<=16000 and core["FF"]<=30000 and core["DSP"]<=64 and core["BRAM18"]+2*core["BRAM36"]<=100
    return core


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--voices",type=int,choices=[1,8,32,64],required=True)
    args=parser.parse_args();out=PHASE/f"voices-{args.voices}-implementation";out.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="integrated_scheduler_cache_AXI_mixer_OOC",voices=args.voices,hardware_verified=False,limit="Internal registered paths; external PS/DDR and board timing require hardware validation")
    try:
        log=run("vivado.bat",["-mode","batch","-source",str(ROOT/"hardware/synth/multivoice.tcl"),"-notrace","-tclargs",str(args.voices)],out)
        assert f"MULTIVOICE_IMPLEMENTATION_COMPLETE voices={args.voices}" in log
        report.update(success=True,core=inspect(out))
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally: (out/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
