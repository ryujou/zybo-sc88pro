"""Verify complete-frame admission, double buffering, abort and read backpressure."""
import json

from phase3 import ROOT,OUT as PHASE
from test_filter_tva import run

OUT=PHASE/"frame-fifo"


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="two_frame_result_FIFO",hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/rtl/pcm_frame_fifo.sv"),str(ROOT/"hardware/sim/tb_frame_fifo.sv")],OUT)
        run("xelab.bat",["tb_frame_fifo","-s","frame_fifo","--debug","typical"],OUT)
        log=run("xsim.bat",["frame_fifo","-runall"],OUT)
        assert "FRAME_FIFO_PASS records=920 reset_positions=4" in log and "Fatal:" not in log
        report.update(success=True,records=920,reset_positions=4,capacity=2,maximum_frame_records=320)
        print("FRAME_FIFO_COMPONENT_PASS records=920 reset_positions=4")
    except Exception as error:
        report["error"]=str(error);raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
