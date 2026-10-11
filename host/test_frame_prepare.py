"""Verify DDR regions, complete frame descriptors and retained PS controls."""
import os
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/verification/offline-player/phase-04/frame-prepare"
SOURCE=r'''
extern "C" {
#include "sc88_frame_prepare.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
static uint64_t le(const uint8_t *p,unsigned bytes) {
    uint64_t value=0;for(unsigned n=0;n<bytes;++n) value|=(uint64_t)p[n]<<(n*8);return value;
}
static sc88_frame_prepare prepare;
static sc88_prepared_frame prepared;
static std::array<uint8_t,16384> output;
static void begin() {
    assert(!sc88_frame_prepare_begin(&prepare,&prepared,output.data(),
           SC88_PARAMETER_BASE+(unsigned)(prepare.frame%SC88_FRAME_SLOTS)*SC88_PARAMETER_SLOT_BYTES));
}
int main(int argc,char **argv) {
    const uint32_t regions[][2]={
        {SC88_PROGRAM_BASE,SC88_PROGRAM_BYTES},{SC88_FILE_A_BASE,SC88_FILE_SLOT_BYTES},
        {SC88_FILE_B_BASE,SC88_FILE_SLOT_BYTES},{SC88_PS_CONTROL_BASE,SC88_FRAME_SLOTS*SC88_PS_CONTROL_STRIDE},
        {SC88_FRAME_COMMAND_BASE,2*SC88_FRAME_COMMAND_STRIDE},{SC88_SEND_RESULT_BASE,2*SC88_SEND_RESULT_STRIDE},
        {SC88_RETURN_AUDIO_BASE,2*SC88_RETURN_AUDIO_STRIDE},{SC88_NATIVE_CAPTURE_BASE,SC88_NATIVE_CAPTURE_BYTES},
        {SC88_PARAMETER_WAVE_BASE,SC88_PARAMETER_WAVE_BYTES},{SC88_PARAMETER_BASE,SC88_FRAME_SLOTS*SC88_PARAMETER_SLOT_BYTES}};
    uint64_t end=0;
    for(auto& region:regions) {
        assert(!(region[0]&31) && !(region[1]&31) && region[0]>=end);
        end=(uint64_t)region[0]+region[1];assert(end<=SC88_DDR_LIMIT);
    }
    for(uint32_t address:{SC88_PARAMETER_BASE-16384,SC88_PARAMETER_BASE+1,
                         SC88_PARAMETER_BASE+SC88_FRAME_SLOTS*SC88_PARAMETER_SLOT_BYTES}) {
        sc88_frame_prepare_init(&prepare,1);
        assert(sc88_frame_prepare_begin(&prepare,&prepared,output.data(),address)<0);
    }
    sc88_frame_prepare_init(&prepare,1);begin();
    uint8_t gate=0;sc88_parameter_event control{};control.kind=4;control.payload=&gate;control.bytes=1;
    for(unsigned n=0;n<256;++n) assert(!sc88_frame_prepare_event(&prepare,&control));
    assert(sc88_frame_prepare_event(&prepare,&control)<0 && prepare.fault);
    sc88_frame_prepare_init(&prepare,1);begin();control.frame=1;
    assert(sc88_frame_prepare_event(&prepare,&control)<0);
    sc88_frame_prepare_init(&prepare,1);begin();
    assert(sc88_frame_prepare_begin(&prepare,&prepared,output.data(),SC88_PARAMETER_BASE)<0);
    sc88_frame_prepare_init(&prepare,0);
    assert(sc88_frame_prepare_begin(&prepare,&prepared,output.data(),SC88_PARAMETER_BASE)<0);
    std::cout<<"regions_and_negative_cases 10 7\n";
    for(int file=1;file<argc;++file) {
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);assert(input);
        sc88_parameter_reader reader;sc88_parameter_reader_init(&reader);
        assert(!sc88_parameter_reader_header(&reader,header.data(),104));
        sc88_frame_prepare_init(&prepare,reader.total_frames);begin();
        uint8_t host_high[8192]{},descriptors[8]{};
        uint16_t highest=63,mask=0,read_address=0xffff;
        unsigned acknowledge=0,control_count=0,max_controls=0,peak_bytes=0;
        uint64_t controls=0,frames=0,bytes=0,result_words=0;
        while(input.peek()!=std::char_traits<char>::eof()) {
            std::array<uint8_t,32> h{};input.read((char*)h.data(),32);assert(input);
            unsigned size=(unsigned)le(h.data()+24,4);assert(size<=SC88_PARAMETER_BLOCK_BYTES);
            std::vector<uint8_t> block(size+32);std::memcpy(block.data(),h.data(),32);
            input.read((char*)block.data()+32,size);assert(input);
            assert(!sc88_parameter_reader_block(&reader,block.data(),size+32));
            sc88_parameter_event e;int status;
            while((status=sc88_parameter_reader_next(&reader,&e))>0) {
                if(e.kind==8) continue;
                int ready=sc88_frame_prepare_event(&prepare,&e);
                if(ready<0) {std::cerr<<"prepare fault file="<<file<<" frame="<<e.frame<<'\n';return 1;}
                if(e.kind>=1 && e.kind<=4) {
                    uint64_t saved=prepared.controls[control_count++];++controls;
                    assert((saved&255)==e.kind && ((saved>>8)&255)==e.target && (saved>>40)==0);
                    unsigned address=(e.kind==2 || e.kind==3)?(unsigned)le(e.payload,2):0;
                    unsigned value=e.kind==2?e.payload[2]:e.kind==4?e.payload[0]:0;
                    assert(((saved>>16)&65535)==address && ((saved>>32)&255)==value);
                    if(e.target==1 && (e.kind==2 || e.kind==3)) {
                        address&=0x3fff;
                        if(e.kind==2) {
                            read_address=0xffff;
                            if(!(address&1)) host_high[address>>1]=(uint8_t)value;
                            else {
                                unsigned word=(host_high[address>>1]<<8)|value,a=address-1;
                                if(a==0x3914) highest=(uint16_t)word;
                                if(a==0x3918) mask=(uint16_t)word;
                                if(a>=0x3908 && a<0x3910) {descriptors[a-0x3908]=(uint8_t)word;descriptors[a-0x3907]=(uint8_t)(word>>8);}
                            }
                        } else {
                            unsigned word=address&~1u;
                            if(!(address&1) || read_address!=word) {
                                if(word==0x391a) acknowledge=1;
                                read_address=(uint16_t)word;
                            }
                            if(address&1) read_address=0xffff;
                        }
                    }
                }
                if(e.kind==5) {
                    assert(ready==1 && prepared.control_count==control_count);
                    uint64_t descriptor=le(descriptors,8);
                    assert(prepared.command[0]==(0x53434431ULL|((uint64_t)acknowledge<<32)|((uint64_t)(frames+1==reader.total_frames)<<33)));
                    assert(prepared.command[1]==frames && prepared.command[3]==descriptor);
                    assert(prepared.command[2]==((uint64_t)prepared.parameter_bytes<<32|
                           (SC88_PARAMETER_BASE+(frames%32)*16384)));
                    assert(prepared.command[4]==((highest&63)|31ULL<<8|(uint64_t)mask<<16));
                    assert(!(prepared.command[5]|prepared.command[6]|prepared.command[7]));
                    assert(prepared.result_words==((highest&63u)+1)*4+64);
                    if(control_count>max_controls) max_controls=control_count;
                    if(prepared.parameter_bytes>peak_bytes) peak_bytes=prepared.parameter_bytes;
                    bytes+=prepared.parameter_bytes;result_words+=prepared.result_words;++frames;
                    control_count=acknowledge=0;
                    if(frames<reader.total_frames) begin();
                } else assert(!ready);
            }
            assert(status==0);
        }
        assert(!sc88_parameter_reader_eof(&reader,0) && reader.complete && frames==prepare.total_frames);
        std::cout<<file<<' '<<frames<<' '<<bytes<<' '<<peak_bytes<<' '<<controls<<' '<<max_controls<<' '<<result_words<<std::endl;
    }
}
'''


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="PS_frame_descriptors_and_DDR_contract",hardware_verified=False)
    (OUT/"summary.json").write_text(json.dumps(report),encoding="utf-8")
    def run(command,log):
        result=subprocess.run(list(map(str,command)),cwd=OUT,capture_output=True,text=True)
        (OUT/log).write_text(result.stdout+result.stderr,encoding="utf-8");result.check_returncode();return result.stdout
    compiler=(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin")
    ps=ROOT/"software/ps";flags=["-O2","-Wall","-Wextra","-Werror","-I",ps]
    objects=[]
    for name in ["sc88_frame_prepare","sc88_parameter_reader","sc88_parameter_frame","sc88_host_config"]:
        obj=OUT/(name+".o");objects.append(obj)
        run([compiler/"gcc.exe","-std=c11",*flags,"-c",ps/(name+".c"),"-o",obj],name+".log")
    arm=(Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm,"-std=c11",*flags,"-mcpu=cortex-a9","-mfpu=vfpv3","-mfloat-abi=hard","-c",
         ps/"sc88_frame_prepare.c","-o",OUT/"prepare-arm.o"],"arm-compile.log")
    (OUT/"test.cpp").write_text(SOURCE,encoding="utf-8")
    run([compiler/"g++.exe","-std=c++17",*flags,OUT/"test.cpp",*objects,"-o",OUT/"test.exe"],"link.log")
    files=[ROOT/"build/verification/offline-player/phase-01/cases"/f"th06_{n:02d}"/"export/song.scp" for n in range(1,8)]
    print("ARM compile passed; validating full MIDI frame descriptors and PS controls",flush=True)
    output=run([OUT/"test.exe",*files],"scan.log");print(output,end="",flush=True)
    rows=[line.split() for line in output.splitlines()];assert len(rows)==8
    previous=json.loads((ROOT/"build/verification/offline-player/phase-04/parameter-reader/summary.json").read_text(encoding="utf-8"))
    packed=json.loads((ROOT/"build/verification/offline-player/phase-04/parameter-frame/summary.json").read_text(encoding="utf-8"))
    assert previous["success"] and packed["success"]
    songs=[]
    for row,known,packing in zip(rows[1:],previous["songs"],packed["songs"]):
        index,frames,bytes_out,peak,controls,max_controls,results=map(int,row)
        assert frames==known["frames"] and controls==sum(known["kinds"][:4])
        assert bytes_out==packing["normalized_bytes"] and peak==packing["peak_bytes"]
        songs.append(dict(song=known["song"],frames=frames,PS_controls=controls,max_PS_controls=max_controls,result_words=results))
    report.update(success=True,arm_compile=True,nonoverlapping_DDR_regions=10,negative_cases=7,songs=songs,
                  limitation="CPU descriptor preparation; PL command consumer, cache handoff, block lifecycle and real-time hardware remain unverified")
    (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
