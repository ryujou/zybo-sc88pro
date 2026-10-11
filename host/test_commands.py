"""Exercise board command decoding, configuration fences and audio due deadlines."""
import json
import re
import struct
from phase4 import ROOT, OUT
from prepare_board_trace import make_trace, HEADER, BLOCK
from test_filter_tva import run


def main():
    out=OUT/"commands";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        data,trace=make_trace(ROOT/"build/verification/phase-03/golden/64_locality",128)
        words=[]
        for i in range(trace["blocks"]):
            offset,length,*_=BLOCK.unpack_from(data,HEADER.size+i*BLOCK.size)
            words.extend(struct.unpack_from(f"<{length//8}Q",data,offset))
        # Explicit IRQ acknowledgement between two frames exercises completion ordering.
        words.insert(words.index((1<<60)|63)+1,2<<60)
        inputs=out/"commands.hex"
        inputs.write_text("".join(f"{v:016x}\n" for v in words),encoding="utf-8")
        run("xvlog.bat",["--sv",str(ROOT/"hardware/board/pcm_commands.sv"),str(ROOT/"hardware/sim/tb_commands.sv")],out)
        run("xelab.bat",["tb_commands","-s","commands","--debug","typical"],out)
        log=run("xsim.bat",["commands","-runall","-testplusarg",'"input=commands.hex"',
                             "-testplusarg",f'"count={len(words)}"',"-testplusarg",'"frames=128"'],out)
        result=re.search(r"COMMAND_STREAM frames=(\d+) configs=(\d+) irq_clears=(\d+) ticks=(\d+) max_due=(\d+)",log)
        assert result and "COMMANDS_PASS checks=12" in log and "Fatal:" not in log,"Command stream test failed"
        summary.update(success=True,frames=int(result[1]),configurations=int(result[2]),irq_clears=int(result[3]),
                       due_ticks=int(result[4]),max_mock_due_cycles=int(result[5]),checks=12)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
