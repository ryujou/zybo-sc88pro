"""Observe serial pins independently of the transmitter's bit counters."""
import json
import re
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"i2s";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_i2s.sv"),str(ROOT/"hardware/sim/tb_i2s.sv")],out)
        run("xelab.bat",["tb_i2s","-s","i2s","--debug","typical"],out)
        log=run("xsim.bat",["i2s","-runall"],out)
        (out/"positive.log").write_text(log,encoding="utf-8")
        result=re.search(r"I2S_PASS frames=(\d+) accepted=(\d+) reset_positions=384 period=384 bclk_divider=6",log)
        assert result and "Fatal:" not in log,"I2S serial comparison failed"
        try:negative=run("xsim.bat",["i2s","-testplusarg","damage_sample","-runall"],out)
        except RuntimeError:negative=(out/"xsim.bat.log").read_text(encoding="utf-8")
        (out/"negative.log").write_text(negative,encoding="utf-8")
        assert "I2S_SAMPLE_DIFFERENCE" in negative and "I2S_PASS" not in negative
        summary.update(success=True,frames=int(result[1]),accepted=int(result[2]),reset_positions=384,sample_fault_detected=True)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
