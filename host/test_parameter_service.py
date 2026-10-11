"""Mock MMIO/Cache ownership service using all seven complete real Touhou parameter files."""
import os
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-service"
SOURCE = r'''
extern "C" {
#include "sc88_parameter_service.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
static sc88_parameter_blocks b;
static sc88_parameter_service s;
static std::vector<uint64_t> controls(32*4096/8),commands(2*4096/8),parameters(32*16384/8);
static std::vector<uint64_t> results(2*65536/8),audio(2*4096/8),dma(2*65536/8);
static uint32_t regs[128],desc[4][8];
static unsigned owner[4],clean[4],param_clean[32],command_clean[2];
static uint64_t barriers,clean_barrier[4],ticks,returned,next_result,next_audio;
static bool corrupt,stop_seen;
static unsigned musical_updates;
static uint64_t sample(uint64_t frame) {
    int32_t left=(int32_t)(frame%8388608),right=-left;
    return (uint32_t)left | (uint64_t)(uint32_t)right<<32;
}
extern "C" uint32_t sc88_read32(unsigned offset) {
    if(offset==0x80) return owner[0]|owner[1]<<2;
    if(offset==0x88) return owner[2]|owner[3]<<2;
    return regs[offset/4];
}
extern "C" void sc88_barrier() {++barriers;}
extern "C" uint64_t sc88_time_us() {return ticks++;}
extern "C" void sc88_flush(uintptr_t address,size_t bytes) {
    for(unsigned slot=0;slot<2;++slot) {
        if(address==(uintptr_t)(results.data()+slot*65536/8)) {assert(false);}
        if(address==(uintptr_t)(audio.data()+slot*4096/8)) {assert(!owner[slot+2]);clean[slot+2]=1;clean_barrier[slot+2]=barriers;return;}
        if(address==(uintptr_t)(commands.data()+slot*4096/8)) {assert(!owner[slot]);command_clean[slot]=1;clean_barrier[slot]=barriers;return;}
    }
    for(unsigned i=0;i<32;++i) if(address==(uintptr_t)(parameters.data()+i*16384/8)) {
        assert(!owner[i/16] && bytes==sc88_parameter_blocks_frame(&b,i/16,i%16)->parameter_bytes);
        param_clean[i]=1;return;
    }
    assert(false);
}
extern "C" void sc88_invalidate(uintptr_t address,size_t bytes) {
    for(unsigned slot=0;slot<2;++slot) if(address==(uintptr_t)(results.data()+slot*65536/8)) {
        assert(bytes==b.input[slot].result_bytes);
        assert(owner[slot]==3);std::memcpy((void*)address,dma.data()+slot*65536/8,bytes);
        return;
    }
    assert(false);
}
extern "C" void sc88_write32(unsigned offset,uint32_t value) {
    if(offset>=0x100) {
        unsigned slot=offset>=0x180 ? 2+(offset-0x180)/32 : (offset-0x100)/32;
        unsigned word=(offset%32)/4;assert(slot<4);
        if(word<7) {assert(!owner[slot]);desc[slot][word]=value;return;}
        if(value==2) {assert(owner[slot]==3);owner[slot]=0;return;}
        assert((value==1 || value==0x101) && !owner[slot]);
        assert(barriers>clean_barrier[slot]);
        if(slot<2) {
            assert(command_clean[slot]);command_clean[slot]=0;
            assert(desc[slot][0]==SC88_FRAME_COMMAND_BASE+slot*4096 && desc[slot][1]==desc[slot][4]*64);
            assert(desc[slot][2]==SC88_SEND_RESULT_BASE+slot*65536 && desc[slot][3]==b.input[slot].result_bytes);
            for(unsigned i=0;i<desc[slot][4];++i) {assert(param_clean[slot*16+i]);param_clean[slot*16+i]=0;}
        } else {
            assert(clean[slot]);clean[slot]=0;
            assert(desc[slot][0]==SC88_RETURN_AUDIO_BASE+(slot-2)*4096 && desc[slot][1]==desc[slot][4]*8);
            assert(!desc[slot][2] && !desc[slot][3]);
        }
        desc[slot][7]=value;owner[slot]=1;return;
    }
    if(offset==4) {
        if(value==8) {stop_seen=true;return;}
        if(value==1) {assert(owner[0]==1 && (owner[1]==1 || desc[0][7]==0x101));regs[2]|=2;}
        else if(value==16) {assert(regs[2]&2);assert(regs[15]>=32 || (regs[15] && regs[0x8c/4]));regs[2]|=128;}
        else assert(false);
    } else if(offset==0x10) regs[4]&=~value;
    else if(offset!=0x14) assert(false);
}
static void init(uint64_t total) {
    std::memset(regs,0,sizeof(regs));std::memset(desc,0,sizeof(desc));std::memset(owner,0,sizeof(owner));
    std::memset(clean,0,sizeof(clean));
    std::memset(param_clean,0,sizeof(param_clean));std::memset(command_clean,0,sizeof(command_clean));
    regs[0]=0x53435034;regs[2]=1;regs[0x84/4]=7;barriers=ticks=returned=next_result=next_audio=0;
    corrupt=stop_seen=false;musical_updates=0;
    sc88_parameter_blocks_init(&b,total,(uint8_t*)controls.data(),(uint8_t*)commands.data(),(uint8_t*)parameters.data());
    assert(!sc88_parameter_service_init(&s,&b,(uint8_t*)results.data(),(uint8_t*)audio.data(),0,1));
}
static void tick(bool hold_audio=false) {
    if(stop_seen) return;
    if(regs[2]&2) for(unsigned slot=0;slot<2;++slot) {
        if(owner[slot]!=1 || desc[slot][5]!=next_result) continue;
        if(!(regs[2]&128) && next_result>=32) continue;
        unsigned pos=slot*65536/8;
        for(unsigned i=0;i<desc[slot][4];++i) {
            auto frame=sc88_parameter_blocks_frame(&b,slot,i);
            unsigned sends=frame->result_words-64;
            for(unsigned k=0;k<sends;++k) dma[pos++]=0;
            for(unsigned cell=0;cell<64;++cell) {
                int32_t v=cell==0 ? (int32_t)((next_result+i)%8388608) : cell==1 ? -(int32_t)((next_result+i)%8388608) : 0;
                dma[pos++]=(1ull<<63)|(uint64_t)cell<<40|((uint32_t)v&0x1ffffff);
            }
            if(corrupt) dma[pos-64]=0;
        }
        next_result+=desc[slot][4];owner[slot]=3;regs[4]|=1u<<slot;
    }
    if(!hold_audio) for(unsigned slot=2;slot<4;++slot) {
        if(owner[slot]!=1 || desc[slot][5]!=next_audio) continue;
        for(unsigned i=0;i<desc[slot][4];++i) assert(audio[(slot-2)*4096/8+i]==sample(next_audio+i));
        next_audio+=desc[slot][4];returned+=desc[slot][4];regs[15]+=desc[slot][4];
        if(desc[slot][7]==0x101) regs[0x8c/4]=1;
        owner[slot]=3;regs[4]|=1u<<slot;
    }
    if(regs[2]&128) {
        regs[15]=0;
        if(regs[0x8c/4]) regs[2]|=16;
    }
}
static void push(const sc88_parameter_event& e) {
    unsigned attempts=0;
    while(1) {
        int status=sc88_parameter_blocks_event(&b,&e);assert(status>=0);
        assert(sc88_parameter_service_poll(&s)>=0);tick();
        if(status) {
            if(e.kind==5 && e.frame>=256000) {
                auto frame=sc88_parameter_blocks_frame(&b,(unsigned)(e.frame/16)%2,(unsigned)e.frame%16);
                if(frame->parameter_bytes>32) ++musical_updates;
            }
            return;
        }
        assert(++attempts<10);
    }
}
static void short_song(unsigned frames) {
    init(frames);sc88_parameter_event e{};e.kind=5;
    for(unsigned i=0;i<frames;++i) {e.frame=i;push(e);}
    e.kind=8;e.frame=frames;push(e);assert(!sc88_parameter_blocks_finish(&b));
    for(unsigned i=0;i<20;++i) {
        int status=sc88_parameter_service_poll(&s);assert(status>=0);tick();
        if(status==1) {assert(returned==frames && s.audio_started && !s.fault);return;}
    }
    assert(false);
}
static void negative_tests() {
    init(64);regs[3]=1;assert(sc88_parameter_service_poll(&s)<0 && s.fault && stop_seen);
    init(64);regs[2]|=16;assert(sc88_parameter_service_poll(&s)<0 && stop_seen);
    init(64);sc88_parameter_event e{};e.kind=5;
    for(unsigned i=0;i<32;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));
    assert(b.input[0].owner==SC88_INPUT_SUBMITTED && b.audio[0].owner==SC88_AUDIO_FREE);
    corrupt=true;tick();assert(sc88_parameter_service_poll(&s)<0 && stop_seen);
    assert(owner[2]==0 && owner[3]==0 && b.input[0].owner==SC88_INPUT_RESULT_READY);
    init(64);
    for(unsigned i=0;i<32;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));tick(true);assert(!sc88_parameter_service_poll(&s));
    assert(b.input[0].owner==SC88_INPUT_FREE && b.audio[0].owner==SC88_AUDIO_DMA);
    uint64_t saved=audio[0];
    // Isolate ownership under a running consumer whose audio DMA is delayed.
    s.audio_started=1;regs[2]|=128;
    for(unsigned i=32;i<48;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));tick(true);assert(!sc88_parameter_service_poll(&s));
    assert(b.input[0].owner==SC88_INPUT_RESULT_READY && b.audio[0].owner==SC88_AUDIO_DMA && audio[0]==saved);
    assert(!(regs[4]&1)); // No repeated input IRQ while waiting for an independent audio slot.
    sc88_parameter_service_stop(&s);assert(stop_seen && b.stopped && sc88_parameter_service_poll(&s)<0);
    assert(b.input[0].owner==SC88_INPUT_RESULT_READY && b.audio[0].owner==SC88_AUDIO_DMA);
    init(80);
    for(unsigned i=0;i<32;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));tick();
    assert(!sc88_parameter_service_poll(&s));tick();
    assert(!sc88_parameter_service_poll(&s));
    assert(regs[15]==32 && !s.audio_started);
    for(unsigned i=32;i<48;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));tick();
    assert(!s.audio_started && next_result==32);
    for(unsigned i=48;i<64;++i) {e.frame=i;assert(sc88_parameter_blocks_event(&b,&e)==1);}
    assert(!sc88_parameter_service_poll(&s));assert(s.audio_started);
}
static uint32_t le32(const uint8_t *p) {return p[0]|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
int main(int argc,char **argv) {
    for(unsigned frames:{1,15,16,17,31,32,33,64,65}) short_song(frames);
    negative_tests();std::cout<<"directed 9 6\n";
    for(int file=1;file<argc;++file) {
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);assert(input);
        sc88_parameter_reader reader;sc88_parameter_reader_init(&reader);
        assert(!sc88_parameter_reader_header(&reader,header.data(),104));init(reader.total_frames);
        while(input.peek()!=std::char_traits<char>::eof()) {
            std::array<uint8_t,32> h{};input.read((char*)h.data(),32);assert(input);
            unsigned size=le32(h.data()+24);assert(size<=SC88_PARAMETER_BLOCK_BYTES);
            std::vector<uint8_t> block(size+32);std::memcpy(block.data(),h.data(),32);
            input.read((char*)block.data()+32,size);assert(input);
            assert(!sc88_parameter_reader_block(&reader,block.data(),size+32));
            sc88_parameter_event e;int status;
            while((status=sc88_parameter_reader_next(&reader,&e))>0) push(e);
            assert(status==0);
        }
        assert(!sc88_parameter_reader_eof(&reader,0) && reader.complete);
        assert(!sc88_parameter_blocks_finish(&b));
        int status=0;
        for(unsigned i=0;i<20 && status==0;++i) {status=sc88_parameter_service_poll(&s);assert(status>=0);tick();}
        assert(status==1 && returned==reader.total_frames && !s.fault && musical_updates);
        sc88_parameter_service_stop(&s);
        std::cout<<file<<' '<<returned<<' '<<barriers<<' '<<musical_updates<<std::endl;
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="PS_parameter_service_mock_MMIO_Cache", success=False, hardware_verified=False)
    (OUT / "summary.json").write_text(json.dumps(report), encoding="utf-8")
    def run(command, log):
        result = subprocess.run(list(map(str, command)), cwd=OUT, capture_output=True, text=True)
        (OUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
        result.check_returncode()
        return result.stdout
    compiler = (Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin")
    ps = ROOT / "software/ps"
    flags = ["-O2", "-Wall", "-Wextra", "-Werror", "-I", ps]
    objects = []
    for name in ["sc88_parameter_service", "sc88_parameter_audio", "sc88_parameter_blocks", "sc88_frame_prepare",
                 "sc88_parameter_reader", "sc88_parameter_frame", "sc88_host_config"]:
        obj = OUT / (name + ".o")
        objects.append(obj)
        run([compiler / "gcc.exe", "-std=c11", *flags, "-c", ps / (name + ".c"), "-o", obj], name + ".log")
    arm = (Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm, "-std=c11", *flags, "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-c",
         ps / "sc88_parameter_service.c", "-o", OUT / "service-arm.o"], "arm-compile.log")
    (OUT / "test.cpp").write_text(SOURCE, encoding="utf-8")
    run([compiler / "g++.exe", "-std=c++17", *flags, OUT / "test.cpp", *objects, "-o", OUT / "test.exe"], "link.log")
    files = [ROOT / "build/verification/offline-player/phase-01/cases" / f"th06_{n:02d}" / "export/song.scp" for n in range(1, 8)]
    output = run([OUT / "test.exe", *files], "test.log")
    print(output, end="", flush=True)
    rows = [line.split() for line in output.splitlines()]
    assert len(rows) == 8 and rows[0] == ["directed", "9", "6"]
    known = json.loads((OUT.parent / "frame-prepare/summary.json").read_text(encoding="utf-8"))
    assert known["success"]
    songs = []
    for row, reference in zip(rows[1:], known["songs"]):
        index, frames, barriers, updates = map(int, row)
        assert frames == reference["frames"] and barriers >= (frames // 16) * 9 and updates > 0
        songs.append(dict(song=f"th06_{index:02d}", first_frame=0, frames=frames, musical_parameter_frames=updates))
    report.update(success=True, arm_compile=True, short_lengths=9, lifecycle_checks=6, songs=songs,
                  limitation="Seven complete real MIDI parameter files including actual EOF; modeled MMIO/DMA/Cache and synthetic mixer records. No RTL audio, board cache coherence or real-time performance evidence.")
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
