"""AXI-Lite independent channels, byte strobes and stalled transaction checks."""
import json
import re
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"axi-control";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_axi_control.sv"),str(ROOT/"hardware/sim/tb_axi_control.sv")],out)
        run("xelab.bat",["tb_axi_control","-s","axi_control","--debug","typical"],out)
        log=run("xsim.bat",["axi_control","-runall"],out)
        result=re.search(r"AXI_CONTROL_PASS writes=(\d+) reads=(\d+) independent_channels=1 stalls=1 reset_partial=1",log)
        assert result and "Fatal:" not in log,"AXI control comparison failed"
        summary.update(success=True,writes=int(result[1]),reads=int(result[2]))
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
