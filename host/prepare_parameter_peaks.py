"""Locate actual SC88PAR1 peaks and normalize their executable PC fields."""
from collections import defaultdict
import json
import struct
import subprocess

import phase0 as p0
import offline_parameter_format as fmt
import offline_parameter_dma as dma

ROOT=p0.ROOT
OUT=ROOT/"build/verification/offline-player/phase-03/parameter-peaks"


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    songs=json.loads((ROOT/"build/verification/offline-player/phase-01/songs.json").read_text(encoding="utf-8"))["songs"]
    measured=[];blocks={}
    for song in songs:
        path=ROOT/"build/verification/offline-player/phase-01/cases"/song["case"]/"export/song.scp"
        stats=json.loads(subprocess.check_output([str(ROOT/"build/offline-player/Release/sc88_parameter_replay.exe"),"--scan",str(path),p0.LOCK["commit"]],text=True,encoding="utf-8"))
        for key in ["frames","records","event_bytes","peak_frame_event_bytes","peak_aligned_16_frame_event_bytes","largest_block_bytes"]:
            assert stats[key]==song["parameters"][key],(song["case"],key)
        measured.append(dict(case=song["case"],path=path,stats=stats))
        indices=[]
        with path.open("rb") as stream:
            stream.seek(fmt.HEADER.size)
            while header:=stream.read(fmt.BLOCK.size):
                magic,index,first,last,size,count=fmt.BLOCK.unpack(header)
                assert magic==b"PBL1"
                indices.append(dict(index=index,first=first,last=last,offset=stream.tell(),size=size,count=count))
                stream.seek(size,1)
        assert max(b["size"]+32 for b in indices)==stats["largest_block_bytes"]
        blocks[song["case"]]=indices
    sources=[]
    for kind,metric in [("frame","peak_frame_event_bytes"),("window16","peak_aligned_16_frame_event_bytes"),("block","largest_block_bytes")]:
        source=max(measured,key=lambda s:s["stats"][metric]);case=source["case"]
        if kind=="frame": first=last=source["stats"]["peak_frame_index"]
        elif kind=="window16": first=source["stats"]["peak_aligned_16_first_frame"];last=first+15
        else:
            peak=max(blocks[case],key=lambda b:b["size"]);first,last=peak["first"],peak["last"]
        entries=defaultdict(dict);event_sizes=defaultdict(int);host_events=defaultdict(int)
        selected=[b for b in blocks[case] if b["first"]<=last and b["last"]>=first]
        for block in selected:
            with source["path"].open("rb") as stream:
                stream.seek(block["offset"]);payload=stream.read(block["size"])
            offset=0
            for _ in range(block["count"]):
                event=fmt.RECORD.unpack_from(payload,offset);offset+=fmt.RECORD.size
                data=payload[offset:offset+event[7]];offset+=event[7];fmt.validate_event(event,data)
                frame,_,kind_id,stage,_,voice,mask,_=event
                if not first<=frame<=last:continue
                event_sizes[frame]+=24+len(data)
                if kind_id in [2,3,4]:host_events[frame]+=1
                if kind_id in [6,7]:
                    key=(voice,stage)
                    item=entries[frame].setdefault(key,[0,-1,[0]*22])
                    if kind_id==7:item[1]=data[0]
                    else:
                        assert item[0]==0;item[0]=mask;values=iter(struct.unpack(f"<{mask.bit_count()}I",data))
                        for i in range(22):
                            if mask>>i&1:item[2][i]=next(values)
            assert offset==block["size"]
        frames=[];normalized=bytearray()
        for frame in range(first,last+1):
            packets=[(voice,stage,*value) for (voice,stage),value in sorted(entries[frame].items())]
            encoded=dma.encode(frame,[],packets);assert dma.decode(encoded,frame)==(frame,[],packets)
            frames.append(dict(frame=frame,packets=packets,bytes=len(encoded),event_bytes=event_sizes[frame],PS_host_events=host_events[frame]))
            normalized.extend(encoded)
        actual=sum(event_sizes.values())+(32 if kind=="block" else 0)
        assert actual==source["stats"][metric],(kind,actual,source["stats"][metric])
        (OUT/(kind+".dma")).write_bytes(normalized)
        p0.write_json(OUT/(kind+".json"),dict(case=case,kind=kind,frames=frames))
        sources.append(dict(kind=kind,case=case,first_frame=first,last_frame=last,original_peak_bytes=actual,normalized_PC_bytes=len(normalized),packets=sum(len(f["packets"]) for f in frames),PS_host_events=sum(host_events.values())))
    report=dict(success=True,scope="actual_peak_PC_packet_transport",hardware_verified=False,seven_songs_rescanned=True,sources=sources,limit="PC packet transport fixtures. Real host effects are PS-owned; integrated synthetic tests separately include up to 320 genuine configuration words per frame. No source/PCM assertions are normalized.")
    p0.write_json(OUT/"summary.json",report)
    print(json.dumps(report))


if __name__=="__main__":main()
