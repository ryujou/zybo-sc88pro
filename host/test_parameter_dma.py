"""Verify normalized DDR parsing, PC lanes, sparse hooks and malformed frames."""
import json
import struct

from offline_phase3 import ROOT, OUT as PHASE
import offline_parameter_dma as dma
from test_filter_tva import run


def main():
    out=PHASE/"parameter-dma";out.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="offline_parameter_DMA_component",hardware_verified=False)
    packets=[]
    for voice,stage in enumerate([1,2,3,4]):
        mask=dma.STAGE_MASKS[stage]
        values=[0]*22
        for bit in range(22):
            if mask>>bit&1:
                width=1 if bit==21 else 20 if bit>=15 else 18
                values[bit]=((1<<width)-1) & (~0x20000 if 6<=bit<=10 else 0xffffffff)
        packets.append((voice,stage,mask,-1,values))
    for voice in range(4,9): packets.append((voice,4,0,voice-4,[0]*22))
    configs=[(word%64,word,(1<<width)-1) for word,width in dma.WIDTHS.items()]
    data=dma.encode(0,configs,packets)
    good=dma.encode(0,[(0,0,1)],[(0,4,1,-1,[1]+[0]*21)])
    tests=[("all_lanes",data,0)]
    for name,offset,replacement in [
        ("magic",0,b"X"),("frame",8,b"\x01"),("size",16,b"\x20"),("payload_count",20,b"\x04"),
        ("config_count",24,b"\x02"),("packet_count",26,b"\x02"),("flags",28,b"\x01"),
        ("cfg_reserved",36,b"\x01"),("cfg_width",34,b"\x10"),("cfg_word",38,b"\x33"),("cfg_opcode",39,b"\x00"),
        ("packet_reserved",40,b"\x01"),("packet_stage",46,b"\x00"),("packet_opcode",47,b"\x00"),
        ("packet_mask",43,b"\x80"),("value_width",50,b"\x10"),("odd_padding",52,b"\x01"),("padding",56,b"\x01"),
    ]:
        damaged=bytearray(good);damaged[offset:offset+len(replacement)]=replacement
        tests.append((name,damaged,1))
    duplicate=dma.encode(0,[],[(0,4,1,-1,[1]+[0]*21),(1,4,1,-1,[1]+[0]*21)])
    damaged=bytearray(duplicate);struct.pack_into("<Q",damaged,48,struct.unpack_from("<Q",duplicate,32)[0])
    tests.append(("duplicate",damaged,1))
    terminal=bytearray(dma.encode(0,[],[(0,4,0,4,[0]*22)]));struct.pack_into("<Q",terminal,32,struct.unpack_from("<Q",terminal,32)[0] | (1<<47))
    tests.append(("reason",terminal,1))
    hold=bytearray(dma.encode(0,[],[(0,4,1<<10,-1,[0]*10+[1]+[0]*11)]));struct.pack_into("<I",hold,40,0x20000)
    tests.append(("hold",hold,1))
    peak_cases=[]
    for kind in ["frame","window16","block"]:
        peak=json.loads((PHASE/"parameter-peaks"/(kind+".json")).read_text(encoding="utf-8"))
        for frame in peak["frames"]:
            peak_cases.append((frame["frame"],frame["packets"]))
            tests.append((kind+"_"+str(frame["frame"]),dma.encode(frame["frame"],[],frame["packets"]),0))
    with (out/"vectors.txt").open("w",encoding="utf-8",newline="\n") as stream:
        for name,frame,negative in tests:
            absolute=dma.HEADER.unpack_from(frame)[1] if name.startswith(("frame_","window16_","block_")) else 0
            stream.write(f"{len(frame)//32} {negative} {absolute} {int(name.startswith('cfg_'))}\n")
            for offset in range(0,len(frame),32): stream.write(f"{int.from_bytes(frame[offset:offset+32],'little'):064x}\n")
            if not negative:
                _,actual_configs,actual_packets=dma.decode(frame,absolute)
                stream.write(f"{len(actual_configs)}\n")
                for config in actual_configs: stream.write(" ".join(map(str,config))+"\n")
                if name=="all_lanes":
                    expected={(v,s):(m,t,values) for v,s,m,t,values in packets}
                    requests=[(v,s,*expected.get((v,s),(0,-1,[0]*22))) for v in range(9) for s in range(1,5)]
                else:requests=actual_packets
                stream.write(f"{len(requests)}\n")
                for voice,stage,mask,terminal,values in requests:stream.write(" ".join(map(str,[voice,stage,mask,terminal,*values]))+"\n")
    try:
        run("xvlog.bat",["--sv",str(ROOT/"hardware/rtl/pcm_parameter_dma.sv"),str(ROOT/"hardware/sim/tb_parameter_dma.sv")],out)
        run("xelab.bat",["tb_parameter_dma","-s","parameter_dma","--debug","typical"],out)
        log=run("xsim.bat",["parameter_dma","-runall"],out)
        assert f"PARAMETER_DMA_PASS cases={len(tests)}" in log and "Fatal:" not in log
        report.update(success=True,cases=len(tests),configs=51,hooks=36,packets=9,fields=22,actual_peak_frames=len(peak_cases),actual_peak_packets=sum(len(p) for _,p in peak_cases),negative_cases=[name for name,_,negative in tests if negative])
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally:(out/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
