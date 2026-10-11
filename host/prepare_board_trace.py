"""Pack only initial state and explicit controls for the board's block command DMA."""
import argparse
import csv
import json
import re
import struct
from collections import defaultdict
from pathlib import Path

from phase4 import ROOT,OUT

HEADER=struct.Struct("<4sIIIIIQQIIIIII")
BLOCK=struct.Struct("<IIIIQQ")
FRAME=1<<60
IRQ=2<<60
END=3<<60


def rows(path):
    with path.open(encoding="utf-8",newline="") as stream:
        yield from csv.DictReader(stream)


def config_word(voice,word,value):
    assert 0<=voice<64 and 0<=word<51 and 0<=value<=0xffffffff
    return (word<<40)|(voice<<32)|value


def make_trace(directory,frames,voices=64,piano=False,left=0,right=1):
    assert frames>0 and voices in [1,8,32,64] and 0<=left<64 and 0<=right<64
    fields=json.loads((ROOT/"reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    by_name={f["name"]:f for f in fields}
    initial=next(rows(directory/("voice-initial.csv" if piano else "initial.csv")))
    first=int(initial["sampleClock"])
    inputs=[directory/("voice-initial.csv" if piano else "initial.csv"),directory/("voice-controls.csv" if piano else "events.csv")]
    boot=[]
    for voice in range(voices):
        for field in fields:
            key=f"voice[{voice}].{field['name']}"
            value=int(initial.get(key,0))
            assert 0<=value<1<<field["width"],key
            if value:boot.append(config_word(voice,field["word"],value))
    controls=defaultdict(list)
    for event in rows(inputs[1]):
        frame=int(event["frame"])
        if not first<=frame<first+frames:continue
        name,value=event["event"],int(event["value"])
        match=re.fullmatch(r"voice\[(\d+)\]\.(.*)",name)
        if match:
            voice=int(match[1]);field=by_name[match[2]]
            assert voice<voices and 0<=value<1<<field["width"]
            controls[frame].append(config_word(voice,field["word"],value))
        else:
            assert name=="interrupt" and value==0,"Unsupported external control: "+name
            controls[frame].append(IRQ)
    count=(frames+15)//16
    offset=(HEADER.size+BLOCK.size*count+63)&~63
    payload=bytearray(offset);blocks=[];command_count=0
    for block in range(count):
        start=block*16;length=min(16,frames-start)
        commands=list(boot) if block==0 else []
        for local in range(length):
            commands.extend(controls[first+start+local]);commands.append(FRAME|(voices-1))
        if block==count-1:commands.append(END)
        byte_count=len(commands)*8
        blocks.append((offset,byte_count,length,int(block==count-1),first+start,0))
        payload.extend(struct.pack(f"<{len(commands)}Q",*commands));command_count+=len(commands)
        padding=(-len(payload))%64;payload.extend(bytes(padding));offset=len(payload)
    assert len(payload)<=32<<20
    descriptors=sum(int(initial[f"waveRomConfig[{i}]"])<<(8*i) for i in range(8))
    HEADER.pack_into(payload,0,b"SC4T",1,len(payload),count,frames,voices,first,descriptors,
                     int(initial["irqStatus"]),int(initial["irqConfigMask"]),31,0,left|(right<<8),int(initial["interrupt"]))
    for index,block in enumerate(blocks):BLOCK.pack_into(payload,HEADER.size+index*BLOCK.size,*block)
    return payload,dict(frames=frames,voices=voices,blocks=count,commands=command_count,first_frame=first,
                        input_files=[str(p.relative_to(ROOT)) for p in inputs],state_input="initial state and explicit controls only")


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--case",default="64_locality")
    parser.add_argument("--frames",type=int,default=128)
    parser.add_argument("--voices",type=int,choices=[1,8,32,64],default=64)
    parser.add_argument("--piano",action="store_true")
    parser.add_argument("--left",type=int,default=0);parser.add_argument("--right",type=int,default=1)
    args=parser.parse_args()
    directory=ROOT/("build/verification/phase-02-rtl/reference/trace-piano" if args.piano else f"build/verification/phase-03/golden/{args.case}")
    if args.piano:assert args.voices==64
    else:
        manifest=list(rows(ROOT/"build/verification/phase-03/golden/manifest.csv"))
        case=next(c for c in manifest if c["case"]==args.case)
        assert args.voices==int(case["voices"]) and args.frames<=int(case["frames"])
    if args.piano:assert args.frames<=256000
    data,summary=make_trace(directory,args.frames,args.voices,args.piano,args.left,args.right)
    out=OUT/"input"/("piano" if args.piano else args.case);out.mkdir(parents=True,exist_ok=True)
    (out/"commands.bin").write_bytes(data)
    (out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(summary))


if __name__=="__main__":main()
