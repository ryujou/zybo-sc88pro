"""Implement the complete 64-state single/pair Voice core on the fixed XC7Z010."""
import json
from test_filter_tva import ROOT, run
from test_voice_units_implementation import inspect_reports

OUT=ROOT/"build/verification/phase-02-rtl/voice-implementation"

def inspect():
    core=inspect_reports(["xp3_voice"],OUT)["xp3_voice"]
    assert core["LUT"]<=12000 and core["FF"]<=16000 and core["DSP"]<=32 and core["BRAM18"]+2*core["BRAM36"]<=24, "Phase 2 core resource budget exceeded"
    return core

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(scope="complete_voice_core_out_of_context",success=False,hardware_verified=False,limit="Internal registered paths; external I/O and board timing require system integration")
    try:
        log=run("vivado.bat",["-mode","batch","-source",str(ROOT/"hardware/synth/voice.tcl"),"-notrace"],OUT)
        assert "VOICE_IMPLEMENTATION_COMPLETE" in log
        report.update(success=True,core=inspect())
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")

if __name__=="__main__": main()
