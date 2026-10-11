"""PS register bank: descriptor publication, IRQ ownership and control strobes."""
import json
import re
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"registers";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_registers.sv"),str(ROOT/"hardware/sim/tb_registers.sv")],out)
        run("xelab.bat",["tb_registers","-s","registers","--debug","typical"],out)
        log=run("xsim.bat",["registers","-runall"],out)
        result=re.search(r"REGISTERS_PASS checks=(\d+) descriptor=1 irq_w1c=1 control=1",log)
        assert result and "Fatal:" not in log,"Register bank comparison failed"
        summary.update(success=True,checks=int(result[1]),descriptor=True,irq_w1c=True,control=True)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
