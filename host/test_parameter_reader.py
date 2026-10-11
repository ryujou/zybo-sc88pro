"""Verify the PS block reader, file segmentation and all real MIDI events."""
import os
import ctypes as c
import json
from pathlib import Path
import struct
import subprocess

import offline_parameter_format as fmt

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-reader"
COMMIT = "9af8bb05bcef2994b5dbb60c5c028e978a72aecb"
SCAN = r'''
extern "C" {
#include "sc88_parameter_reader.h"
#include "sc88_parameter_frame.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
static uint32_t le(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
int main(int argc,char **argv) {
    for(int file=1;file<argc;++file) {
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        sc88_parameter_reader reader;sc88_parameter_reader_init(&reader);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);assert(input);
        assert(!sc88_parameter_reader_header(&reader,header.data(),104));
        sc88_host_config host;sc88_host_reset(&host);sc88_host_changes changes;
        sc88_parameter_frame frame;std::array<uint8_t,16384> output{};
        sc88_parameter_frame_begin(&frame,output.data(),0);
        uint64_t total_bytes=0,configs=0,packets=0,kinds[9]{},targets[3]{};
        unsigned maximum=0;
        while(input.peek()!=std::char_traits<char>::eof()) {
            std::array<uint8_t,32> h{};input.read((char*)h.data(),32);assert(input);
            unsigned size=le(h.data()+24);assert(size<=SC88_PARAMETER_BLOCK_BYTES);
            std::vector<uint8_t> block(size+32);std::memcpy(block.data(),h.data(),32);
            input.read((char*)block.data()+32,size);assert(input);
            assert(!sc88_parameter_reader_block(&reader,block.data(),size+32));
            sc88_parameter_event e;int status;
            while((status=sc88_parameter_reader_next(&reader,&e))>0) {
                ++kinds[e.kind];++targets[e.target];
                if(e.kind==1) sc88_host_reset(&host);
                else if((e.kind==2 || e.kind==3) && e.target==1) {
                    uint16_t address=e.payload[0]|(uint16_t)e.payload[1]<<8;
                    if(e.kind==2) sc88_host_write(&host,address,e.payload[2],&changes);
                    else sc88_host_read(&host,address,&changes);
                    if(changes.count) assert(!sc88_parameter_frame_configs(&frame,&changes));
                } else if(e.kind==6 || e.kind==7) {
                    uint32_t values[22];for(unsigned n=0;n<e.bytes/4;++n) values[n]=le(e.payload+n*4);
                    assert(!sc88_parameter_frame_hook(&frame,e.voice,e.stage,e.mask,values,e.kind==7?e.payload[0]:-1));
                } else if(e.kind==5) {
                    unsigned bytes=sc88_parameter_frame_finish(&frame);assert(bytes);
                    total_bytes+=bytes;configs+=frame.configs;packets+=frame.packets;
                    if(bytes>maximum) maximum=bytes;
                    sc88_parameter_frame_begin(&frame,output.data(),reader.frame);
                }
            }
            if(status<0) {std::cerr<<"file="<<file<<" frame="<<reader.frame<<" sequence="<<reader.sequence
                                 <<" fault="<<reader.fault<<'\n';return 1;}
        }
        assert(!sc88_parameter_reader_eof(&reader,0) && reader.complete);
        std::cout<<file<<' '<<reader.frame<<' '<<reader.records<<' '<<reader.block_index<<' '
                 <<total_bytes<<' '<<maximum<<' '<<configs<<' '<<packets;
        for(unsigned n=1;n<9;++n) std::cout<<' '<<kinds[n];
        for(auto count:targets) std::cout<<' '<<count;
        std::cout<<std::endl;
    }
}
'''


class Reader(c.Structure):
    _fields_ = [(n,c.c_uint64) for n in ["frame","total_frames","block_last","records"]] + [
        (n,c.c_uint32) for n in ["sequence","segment","block_index","remaining","bytes","position"]] + [
        (n,c.c_uint) for n in ["need_header","reset_seen","ended","complete","fault","hook_key"]] + [
        ("identity",c.c_uint8*96),("control_seen",c.c_uint8*256),("data",c.POINTER(c.c_uint8))]


class Event(c.Structure):
    _fields_ = [("frame",c.c_uint64)] + [(n,c.c_uint32) for n in ["sequence","mask","bytes"]] + [
        (n,c.c_uint8) for n in ["kind","stage","target","voice"]] + [("payload",c.POINTER(c.c_uint8))]


def header(segment=0,block=0):
    return fmt.HEADER.pack(b"SC88PAR1",1,32000,1,1,0,2,COMMIT.encode(),1,1,segment,block)


def event(frame,seq,kind,stage=0,target=0,voice=255,mask=0,payload=b""):
    return fmt.RECORD.pack(frame,seq,kind,stage,target,voice,mask,len(payload))+payload


def block(index,first,last,events):
    data=b"".join(events)
    return fmt.BLOCK.pack(b"PBL1",index,first,last,len(data),len(events))+data


def changed(data,offset,value,form="<I"):
    result=bytearray(data);struct.pack_into(form,result,offset,value);return bytes(result)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="PS_SC88PAR1_block_reader",hardware_verified=False)
    (OUT/"summary.json").write_text(json.dumps(report),encoding="utf-8")
    def run(command,log):
        result=subprocess.run(list(map(str,command)),cwd=OUT,capture_output=True,text=True)
        (OUT/log).write_text(result.stdout+result.stderr,encoding="utf-8");result.check_returncode()
        return result.stdout
    compiler=(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin")
    source=ROOT/"software/ps/sc88_parameter_reader.c"
    flags=["-std=c11","-O2","-Wall","-Wextra","-Werror"]
    run([compiler/"gcc.exe",*flags,"-shared",source,"-o",OUT/"reader.dll"],"compile.log")
    arm=(Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm,*flags,"-mcpu=cortex-a9","-mfpu=vfpv3","-mfloat-abi=hard","-c",source,"-o",OUT/"reader.o"],"arm-compile.log")
    lib=c.CDLL(str(OUT/"reader.dll"))
    init,head,load,next_event,eof=[getattr(lib,"sc88_parameter_reader_"+n) for n in ["init","header","block","next","eof"]]
    init.argtypes=[c.POINTER(Reader)]
    for fn in [head,load]: fn.argtypes=[c.POINTER(Reader),c.POINTER(c.c_uint8),c.c_uint]
    next_event.argtypes=[c.POINTER(Reader),c.POINTER(Event)]
    eof.argtypes=[c.POINTER(Reader),c.c_uint]
    def check(segments,valid):
        r=Reader();init(c.byref(r));seen=[];error=False
        for index,(h,blocks) in enumerate(segments):
            hb=(c.c_uint8*len(h)).from_buffer_copy(h)
            if head(c.byref(r),hb,len(h)): error=True;break
            for b in blocks:
                raw=(c.c_uint8*len(b)).from_buffer_copy(b)
                if load(c.byref(r),raw,len(b)): error=True;break
                while True:
                    e=Event(kind=0xcc);before=bytes(e)
                    result=next_event(c.byref(r),c.byref(e))
                    if result<0:
                        assert bytes(e)==before;error=True;break
                    if not result: break
                    seen.append((e.frame,e.sequence,e.kind,e.target,bytes(e.payload[:e.bytes])))
                if error: break
            if error: break
            if eof(c.byref(r),index+1<len(segments)): error=True;break
        if valid: assert not error and r.complete and r.frame==2
        else:
            assert error and r.fault
            e=Event(kind=0xab);before=bytes(e)
            assert next_event(c.byref(r),c.byref(e))==-1 and bytes(e)==before
        return seen
    reset=event(0,0,1);frame0=event(0,1,5);frame1=event(1,0,5);end=event(2,0,8)
    b0=block(0,0,0,[reset,frame0]);b1=block(1,1,2,[frame1,end])
    basic=[(header(),[b0,b1])]
    expected=check(basic,True)
    assert check([(header(),[b0]),(header(1,1),[b1])],True)==expected
    # Every PS-owned event is delivered unmodified, including LSP and raw return-gate bytes.
    controls=[reset,event(0,1,2,target=2,payload=b"\x34\x12\x56"),
              event(0,2,3,target=2,payload=b"\x21\x43"),event(0,3,3,payload=b"\x8f\xfe"),
              event(0,4,4,payload=b"\x80"),event(0,5,5)]
    seen=check([(header(),[block(0,0,0,controls),b1])],True)
    assert seen[1:5]==[(0,1,2,2,b"\x34\x12\x56"),(0,2,3,2,b"\x21\x43"),(0,3,3,0,b"\x8f\xfe"),(0,4,4,0,b"\x80")]
    negatives=[]
    def bad(name,segments): check(segments,False);negatives.append(name)
    for name,offset,value in [("version",8,2),("rate",12,44100),("ROM_layout",88,2),
                              ("schema",92,2),("first_segment",96,1),("first_block",100,1)]:
        bad(name,[(changed(header(),offset,value),[b0,b1])])
    for name,h in [("short_header",header()[:-1]),("magic",b"X"+header()[1:]),
                   ("commit",header()[:48]+b"0"*40+header()[88:]),
                   ("zero_boot",changed(header(),16,0,"<Q")),("duration",changed(header(),40,3,"<Q")),
                   ("tail",changed(header(),32,2,"<Q")),("duration_overflow",changed(header(),16,(1<<64)-1,"<Q"))]:
        bad(name,[(h,[b0,b1])])
    for name,b in [("short_block",b0[:31]),("short_payload",b0[:-1]),("block_magic",b"XXXX"+b0[4:]),
                   ("block_order",changed(b0,4,1)),("block_first",changed(b0,8,1,"<Q")),
                   ("block_last",changed(b0,16,3,"<Q")),("block_size",changed(b0,24,8388609)),
                   ("zero_count",changed(b0,28,0)),("count_too_large",changed(b0,28,3)),
                   ("count_too_small",changed(b0,28,1)),("payload_length",changed(b0,32+20,0xffffffff)),
                   ("frame_order",changed(b0,32,1,"<Q")),("sequence",changed(b0,32+8,1)),
                   ("unknown_kind",changed(b0,32+12,9,"<B")),("target",changed(b0,32+14,1,"<B")),
                   ("sentinel",changed(b0,32+15,0,"<B"))]:
        bad(name,[(header(),[b,b1])])
    bad("missing_RESET",[(header(),[block(0,0,0,[event(0,0,5)]),b1])])
    bad("duplicate_RESET",[(header(),[block(0,0,0,[reset,event(0,1,1),event(0,2,5)]),b1])])
    bad("split_frame",[(header(),[block(0,0,0,[reset]),b1])])
    bad("missing_END",[(header(),[b0])])
    bad("early_END",[(header(),[block(0,0,0,[reset,event(0,1,8)])])])
    bad("trailing_block",[(header(),[b0,b1,b1])])
    bad("trailing_segment",[(header(),[b0,b1]),(header(1,2),[])])
    bad("segment_order",[(header(),[b0]),(header(2,1),[b1])])
    bad("segment_block_order",[(header(),[b0]),(header(1,0),[b1])])
    bad("segment_identity",[(header(),[b0]),(changed(header(1,1),32,1,"<Q"),[b1])])
    delta=lambda seq,voice=0: event(0,seq,6,4,1,voice,1,struct.pack("<I",1))
    terminal=lambda seq: event(0,seq,7,4,1,0,0,b"\0")
    check([(header(),[block(0,0,0,[reset,delta(1),terminal(2),event(0,3,5)]),b1])],True)
    for name,events in [("duplicate_delta",[delta(1),delta(2)]),("duplicate_terminal",[terminal(1),terminal(2)]),
                        ("delta_after_terminal",[terminal(1),delta(2)]),("hook_order",[delta(1,1),delta(2,0)]),
                        ("host_after_hook",[delta(1),event(0,2,4,payload=b"\0")]),
                        ("field_width",[event(0,1,6,4,1,0,1,struct.pack("<I",1<<18))]),
                        ("field_hold",[event(0,1,6,4,1,0,1<<10,struct.pack("<I",0x20000))]),
                        ("field_short",[event(0,1,6,4,1,0,1,b"\0")]),
                        ("field_mask",[event(0,1,6,2,1,0,1,struct.pack("<I",0))]),
                        ("bad_terminal",[event(0,1,7,4,1,0,0,b"\5")]),
                        ("bad_IRQ_query",[event(0,1,3,payload=b"\0\0")])]:
        bad(name,[(header(),[block(0,0,0,[reset,*events,event(0,len(events)+1,5)]),b1])])
    print(f"Segment continuity and {len(negatives)} malformed-stream cases passed; scanning real MIDI",flush=True)
    (OUT/"scan.cpp").write_text(SCAN,encoding="utf-8")
    objects=[]
    for name in ["sc88_parameter_reader","sc88_parameter_frame","sc88_host_config"]:
        obj=OUT/(name+"-native.o");objects.append(obj)
        run([compiler/"gcc.exe",*flags,"-c",source.parent/(name+".c"),"-o",obj],name+".log")
    run([compiler/"g++.exe","-std=c++17","-O2","-I",source.parent,OUT/"scan.cpp",*objects,"-o",OUT/"scan.exe"],"scan-build.log")
    files=[ROOT/"build/verification/offline-player/phase-01/cases"/f"th06_{n:02d}"/"export/song.scp" for n in range(1,8)]
    output=run([OUT/"scan.exe",*files],"scan.log");print(output,end="",flush=True)
    rows=[list(map(int,line.split())) for line in output.splitlines()];assert len(rows)==7
    frames=json.loads((ROOT/"build/verification/offline-player/phase-04/parameter-frame/summary.json").read_text(encoding="utf-8"))
    assert frames["success"]
    songs=[]
    for row,known in zip(rows,frames["songs"]):
        index,total,records,blocks,size,peak,configs,packets,*counts=row
        assert (total,size,peak,configs,packets)==tuple(known[k] for k in ["frames","normalized_bytes","peak_bytes","configs","packets"])
        assert sum(counts[:8])==records and sum(counts[8:])==records
        songs.append(dict(song=f"th06_{index:02d}",frames=total,records=records,blocks=blocks,kinds=counts[:8],targets=counts[8:]))
    report.update(success=True,arm_compile=True,negative_cases=negatives,segment_continuity=True,
                  PS_events_preserved=True,songs=songs,limitation="Caller supplies complete logical blocks; FatFs prefetch and hardware timing remain unverified")
    (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
