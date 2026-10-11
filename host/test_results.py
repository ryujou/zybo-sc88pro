"""Ordered result DMA and atomic native audio publication under backpressure."""
import json
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"results";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_results.sv"),str(ROOT/"hardware/sim/tb_results.sv")],out)
        run("xelab.bat",["tb_results","-s","results","--debug","typical"],out)
        log=run("xsim.bat",["results","-runall"],out)
        assert "RESULTS_PASS checks=6 frames=49 routes=3" in log and "Fatal:" not in log,"Result stream comparison failed"
        summary.update(success=True,checks=6,frames=49,routes=3)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
