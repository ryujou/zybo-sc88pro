"""Continuous real Voice core -> ordered results -> async FIFO -> I2S comparison."""
import argparse
import json
import re
import shutil
import struct
from phase4 import ROOT,OUT
from prepare_board_trace import make_trace,HEADER,BLOCK,rows
from test_voice import RTL
from test_filter_tva import run,VIVADO


def vectors(out,case,song=None,piano=False):
    real=song is not None or piano
    source=OUT/"piano" if piano else OUT/"touhou"/song if song else ROOT/"build/verification/phase-03/golden"/case
    states=list(rows(source/"expected.csv"));frames=len(states)
    voices=64 if real else int(case.split("_",1)[0])
    left,right=(8,9) if real else (0,1)
    if real:
        metadata=json.loads((source/"input.json").read_text(encoding="utf-8"))
        assert metadata["success"] and metadata["frames"]==frames and metadata["reference_pcm_exact"]
        shutil.copyfile(source/"decoded-wave.bin",out/"decoded-wave.bin")
    packet,trace=make_trace(source,frames,voices,left=left,right=right)
    header=HEADER.unpack_from(packet)
    (out/"packet.hex").write_text("".join(f"{v:016x}\n" for v in struct.unpack(f"<{len(packet)//8}Q",packet)),encoding="utf-8")
    commands=[]
    blocks=[]
    for index in range(trace["blocks"]):
        offset,length,*_=BLOCK.unpack_from(packet,HEADER.size+index*BLOCK.size)
        commands.extend(struct.unpack_from(f"<{length//8}Q",packet,offset))
        blocks.append(((0x02000000+offset)<<32)|length)
    (out/"blocks.hex").write_text("".join(f"{v:016x}\n" for v in blocks),encoding="utf-8")
    (out/"commands.hex").write_text("".join(f"{v:016x}\n" for v in commands),encoding="utf-8")
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    with (out/"states.hex").open("w",encoding="utf-8") as stream:
        for row in states:
            for voice in range(voices):
                for field in fields:stream.write(f"{int(row[f'voice[{voice}].{field['name']}']):08x}\n")
    (out/"irq.hex").write_text("".join(f"{int(r['irqStatus'])|(int(r['interrupt'])<<16):05x}\n" for r in states),encoding="utf-8")
    sends=iter(rows(source/"sends.csv"));record_count=0
    with (out/"records.hex").open("w",encoding="utf-8") as stream:
        for mix in rows(source/"mix.csv"):
            for _ in range(voices*4):
                r=next(sends)
                word=(int(r["slot"])<<54)|(int(r["voice"])<<48)|(int(r["send"])<<46)|(int(r["destination"])<<40)|(int(r["contribution"])&0x1ffffff)
                stream.write(f"{word:016x}\n");record_count+=1
            for cell in range(64):
                word=(1<<63)|((int(mix["seen"])>>cell&1)<<62)|(cell<<40)|(int(mix[f"cell[{cell}]"])&0x1ffffff)
                stream.write(f"{word:016x}\n");record_count+=1
    reads=list(rows(source/"rom-reads.csv"))
    if real:assert reads,"Real-ROM acceptance window must contain sample reads"
    with (out/"reads.txt").open("w",encoding="utf-8") as stream:
        for r in reads:stream.write(" ".join(r[k] for k in ["frame","voice","chip_select","physical_address","value"])+"\n")
    (out/"vectors.svh").write_text(
        f"localparam integer FRAME_COUNT={frames}, VOICES={voices}, COMMAND_COUNT={len(commands)}, RECORD_COUNT={record_count}, READ_COUNT={len(reads)};\n"
        f"localparam integer BLOCK_COUNT={trace['blocks']}, PACKET_WORDS={len(packet)//8};\n"
        f"localparam [63:0] FIRST_FRAME=64'd{header[6]}, DESCRIPTORS=64'h{header[7]:016x};\n"
        f"localparam [15:0] INITIAL_IRQ=16'd{header[8]}, IRQ_MASK=16'd{header[9]};\n"
        f"localparam INITIAL_INTERRUPT=1'b{header[13]};\n"
        f"localparam integer LEFT_CELL={left}, RIGHT_CELL={right};\n"+
        ("`define REAL_ROM\n" if real else ""),encoding="utf-8")
    return dict(case=case,frames=frames,voices=voices,records=record_count,rom_reads=len(reads))


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--case",default="64_locality")
    selection=parser.add_mutually_exclusive_group()
    selection.add_argument("--song",choices=[f"th06_{i:02}" for i in range(1,8)])
    selection.add_argument("--piano",action="store_true")
    parser.add_argument("--dma",action="store_true");args=parser.parse_args()
    case="piano" if args.piano else args.song or args.case
    out=OUT/("synth-dma" if args.dma else "synth")/case;out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False,block_dma=args.dma)
    try:
        counts=vectors(out,case,args.song,args.piano)
        for table in ["xp3_pitch.mem","xp3_interpolation.mem"]:shutil.copyfile(ROOT/"hardware/rtl"/table,out/table)
        sources=[ROOT/"hardware/rtl"/(name+".sv") for name in RTL+["pcm_mixer","pcm_frame_fifo","pcm_sample_fetcher","pcm_sample_cache","pcm_voice_scheduler"]]
        xpm=VIVADO.parent/"data/ip/xpm"
        sources += [xpm/name/"hdl"/(name+".sv") for name in ["xpm_cdc","xpm_memory","xpm_fifo"]]
        sources += [ROOT/"hardware/board"/(name+".sv") for name in ["pcm_commands","pcm_results","pcm_i2s","pcm_audio_bridge","pcm_synth","pcm_block_queue","pcm_block_dma","pcm_transport"]]
        sources += [ROOT/"hardware/sim/board_dma_fixture.sv",ROOT/"hardware/sim/tb_board_synth.sv",VIVADO.parent/"data/verilog/src/glbl.v"]
        wrapper=out/"board_test.sv"
        wrapper.write_text(f"module board_test; tb_board_synth #(.BLOCK_DMA({int(args.dma)})) test(); endmodule\n",encoding="utf-8")
        sources.append(wrapper)
        run("xvlog.bat",["--sv","-i",str(out),*[str(p) for p in sources]],out)
        run("xelab.bat",["board_test","glbl","-s","board_synth","--debug","typical","-L","unisims_ver"],out)
        log=run("xsim.bat",["board_synth","-runall"],out)
        result=re.search(r"BOARD_SYNTH_PASS frames=(\d+) records=(\d+) reads=(\d+) wire_frames=(\d+) max_core=(\d+) max_due=(\d+)",log)
        assert result and "Fatal:" not in log and "Error:" not in log,"Board synthesis chain comparison failed"
        assert list(map(int,result.groups()[:4]))==[counts["frames"],counts["records"],counts["rom_reads"],counts["frames"]]
        assert int(result[5])<=3125 and int(result[6])<=3125
        summary.update(success=True,**counts,max_core_cycles=int(result[5]),max_due_cycles=int(result[6]),wire_frames=int(result[4]))
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
