"""Verify four-outstanding AXI line reads, backpressure and local-reset draining."""
import json

from phase3 import ROOT, OUT as PHASE
from test_filter_tva import run

OUT=PHASE/"sample-fetcher"


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="AXI_sample_fetcher_component",hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/rtl/pcm_sample_fetcher.sv"),str(ROOT/"hardware/sim/tb_sample_fetcher.sv")],OUT)
        run("xelab.bat",["tb_sample_fetcher","-s","sample_fetcher","--debug","typical"],OUT)
        log=run("xsim.bat",["sample_fetcher","-runall"],OUT)
        assert "SAMPLE_FETCHER_PASS lines=1024 outstanding=4 flush_positions=8 fault_tests=6" in log and "Fatal:" not in log, "AXI sample fetcher did not pass"
        report.update(success=True,lines=1024,outstanding=4,flush_positions=8,fault_tests=6,limit="AXI component simulation; no integrated cache deadline or PS/DDR hardware timing evidence")
        print("SAMPLE_FETCHER_COMPONENT_PASS lines=1024 outstanding=4 flush_positions=8 fault_tests=6")
    except Exception as error:
        report["error"]=str(error);raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
