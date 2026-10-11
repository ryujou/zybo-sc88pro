"""Two DMA descriptors: independent read-ahead, CPU ownership and completion."""
import json
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"block-queue";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_block_queue.sv"),str(ROOT/"hardware/sim/tb_block_queue.sv")],out)
        run("xelab.bat",["tb_block_queue","-s","block_queue","--debug","typical"],out)
        log=run("xsim.bat",["block_queue","-runall"],out)
        assert "BLOCK_QUEUE_PASS checks=75 blocks=8 read_ahead=1 cpu_reuse=1" in log and "Fatal:" not in log,"Block ownership comparison failed"
        summary.update(success=True,checks=75,blocks=8,read_ahead=True,cpu_reuse=True)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
