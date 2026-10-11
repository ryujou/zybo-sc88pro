"""Check independent board artifacts; --load explicitly programs a connected Zybo."""
import os
import argparse
import json
import subprocess
import zipfile
from phase4 import ROOT,OUT
from prepare_board_trace import HEADER,BLOCK


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--song",choices=[f"th06_{i:02}" for i in range(1,8)],default="th06_01")
    parser.add_argument("--load",action="store_true")
    parser.add_argument("--cable-serial",default="")
    args=parser.parse_args()
    if args.load and not args.cable_serial:parser.error("--load requires --cable-serial")
    board=OUT/"board";ps=OUT/"ps";song=OUT/"touhou"/args.song
    assert json.loads((board/"summary.json").read_text(encoding="utf-8"))["success"],"Full-board resource, STA, DRC and CDC audit must pass before accepting JTAG artifacts"
    packet=song/"commands.bin"
    metadata=json.loads((song/"input.json").read_text(encoding="utf-8"))
    assert metadata["success"] and metadata["reference_pcm_exact"]
    assert json.loads((ps/"summary.json").read_text(encoding="utf-8"))["success"]
    data=packet.read_bytes();header=HEADER.unpack_from(data)
    assert header[:3]==(b"SC4T",1,len(data)) and header[4]==metadata["frames"] and header[5]==64
    assert len(data)<=32<<20 and header[4]*8<=8<<20
    # The firmware parser verifies every command and block before starting DMA.
    assert HEADER.size+BLOCK.size*header[3]<=len(data)
    with zipfile.ZipFile(board/"sc88.xsa") as archive:
        bits=[name for name in archive.namelist() if name.endswith(".bit")]
        init=[name for name in archive.namelist() if name.rsplit("/",1)[-1]=="ps7_init.tcl"]
        assert len(bits)==len(init)==1
        assert archive.read(bits[0])==(board/"sc88.bit").read_bytes()
        assert archive.read(init[0])==(ps/"ps7_init.tcl").read_bytes()
    command=[str(Path(os.environ["VITIS_ROOT"]) / "bin/xsct.bat"),ROOT/"scripts/board_jtag.tcl",
             board/"sc88.xsa",board/"sc88.bit",ps/"sc88.elf",ps/"ps7_init.tcl",
             song/"decoded-wave.bin",packet,"load" if args.load else "check",args.cable_serial or "OFFLINE"]
    result=subprocess.run(list(map(str,command)),cwd=ROOT,capture_output=True,text=True,encoding="utf-8",errors="replace")
    (ps/("jtag-load.log" if args.load else "jtag-check.log")).write_text(result.stdout+result.stderr,encoding="utf-8")
    marker="SC88_JTAG_STARTED" if args.load else "SC88_JTAG_OFFLINE_CHECK_COMPLETE"
    assert result.returncode==0 and marker in result.stdout,"JTAG entry failed; see PS log"
    print(result.stdout.strip())


if __name__=="__main__":main()
