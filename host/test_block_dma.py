"""Exercise independent burst DMA channels against a stalled address-indexed DDR model."""
import json
from phase4 import ROOT,OUT
from test_filter_tva import run


def main():
    out=OUT/"block-dma";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_block_dma.sv"),str(ROOT/"hardware/sim/tb_block_dma.sv")],out)
        run("xelab.bat",["tb_block_dma","-s","block_dma","--debug","typical"],out)
        log=run("xsim.bat",["block_dma","-runall"],out)
        assert "BLOCK_DMA_PASS tests=14 crossing_4KiB=1 read_words=256 write_words=257 fault_cases=8 stop_positions=4" in log and "Fatal:" not in log,"Block DMA simulation failed"
        summary.update(success=True,tests=14,fault_cases=8,stop_positions=4)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
