"""Compile and execute the firmware's portable codec, packet and DMA ownership tests."""
import os
import argparse
import json
from pathlib import Path
import subprocess
from phase4 import ROOT,OUT
from prepare_board_trace import HEADER,make_trace


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--packet",type=Path,action="append",default=[],help="Also test an existing board command packet, including its corruption cases")
    args=parser.parse_args()
    out=OUT/"ps-host";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        data,trace=make_trace(ROOT/"build/verification/phase-03/golden/64_locality",128)
        (out/"commands.bin").write_bytes(data)
        source=ROOT/"software/ps"
        compiler=str(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe")
        result=subprocess.run([compiler,"-std=c11","-Wall","-Wextra","-Werror","-O2",*[str(source/name) for name in ["sc88_codec.c","sc88_trace.c","sc88_player.c","test_player.c","test_host.c"]],"-o",str(out/"ps_host.exe")],capture_output=True,text=True)
        (out/"compile.log").write_text(result.stdout+result.stderr,encoding="utf-8")
        assert result.returncode==0,"Host firmware compile failed"
        result=subprocess.run([str(out/"ps_host.exe"),str(out/"commands.bin")],capture_output=True,text=True)
        (out/"test.log").write_text(result.stdout+result.stderr,encoding="utf-8")
        assert result.returncode==0 and "PS_HOST_PASS frames=128 blocks=8 codec_failures=12 trace_negatives=8" in result.stdout,"Firmware host test failed"
        assert "PS_PLAYER_PASS frames=128 blocks=8 services=4 cache_order=1 fault_stop=1 timeout=1" in result.stdout,"Firmware ownership/cache ordering failed"
        for frames in [1,17,33]:
            data,_=make_trace(ROOT/"build/verification/phase-03/golden/64_locality",frames)
            packet=out/f"commands-{frames}.bin";packet.write_bytes(data)
            result=subprocess.run([str(out/"ps_host.exe"),str(packet)],capture_output=True,text=True)
            (out/f"test-{frames}.log").write_text(result.stdout+result.stderr,encoding="utf-8")
            blocks=(frames+15)//16
            assert result.returncode==0 and f"PS_PLAYER_PASS frames={frames} blocks={blocks} services={(blocks+1)//2}" in result.stdout,"Partial final block failed"
        summary.update(frames=128,blocks=8,codec_failures=12,trace_negatives=8,trace=trace,cache_ownership=True,block_services=4,fault_stop=True,ready_timeout=True)
        summary["partial_frame_cases"]=[1,17,33]
        summary["packet_cases"]=[]
        for index,packet in enumerate(args.packet):
            packet=packet.resolve()
            header=HEADER.unpack_from(packet.read_bytes())
            frames,blocks=header[4],header[3]
            result=subprocess.run([str(out/"ps_host.exe"),str(packet)],capture_output=True,text=True)
            (out/f"packet-{index}.log").write_text(result.stdout+result.stderr,encoding="utf-8")
            assert result.returncode==0 and f"PS_HOST_PASS frames={frames} blocks={blocks} codec_failures=12 trace_negatives=8" in result.stdout,"Supplied packet parser/corruption test failed"
            assert f"PS_PLAYER_PASS frames={frames} blocks={blocks} services={(blocks+1)//2}" in result.stdout,"Supplied packet DMA ownership test failed"
            summary["packet_cases"].append(dict(packet=str(packet),frames=frames,blocks=blocks,trace_negatives=8,cache_ownership=True))
        summary["success"]=True
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
