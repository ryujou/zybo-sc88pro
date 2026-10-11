"""Exercise input/audio ownership using the seven complete real MIDI parameter files."""
import os
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-blocks"
SOURCE = r'''
extern "C" {
#include "sc88_parameter_blocks.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
static sc88_parameter_blocks blocks;
static std::vector<uint64_t> controls(32*4096/8),commands(2*4096/8),parameters(32*16384/8);
static std::vector<uint8_t> saved[2];
static uint64_t completed_frames,block_count,controls_count,result_bytes,parameter_bytes,waits;
static void init(uint64_t frames) {
    sc88_parameter_blocks_init(&blocks,frames,(uint8_t*)controls.data(),(uint8_t*)commands.data(),(uint8_t*)parameters.data());
    completed_frames=block_count=controls_count=result_bytes=parameter_bytes=waits=0;
}
static std::vector<uint8_t> snapshot(unsigned slot) {
    std::vector<uint8_t> result;
    auto append=[&](const void *data,unsigned bytes) {
        auto p=(const uint8_t*)data;result.insert(result.end(),p,p+bytes);
    };
    const auto& b=blocks.input[slot];
    append(blocks.commands+slot*4096,b.frames*64);
    for(unsigned n=0;n<b.frames;++n) {
        auto f=sc88_parameter_blocks_frame(&blocks,slot,n);
        append(f,sizeof(*f));append(blocks.parameters+(slot*16+n)*16384,f->parameter_bytes);
    }
    return result;
}
static void submit() {
    for(unsigned count=0;count<2;++count) {
        unsigned slot=blocks.submit_slot;
        if(blocks.input[slot].owner!=SC88_INPUT_READY) break;
        auto& b=blocks.input[slot];
        assert(b.frames && b.frames<=16 && b.result_bytes<=40960);
        if(b.last) assert(blocks.input_complete && blocks.end_seen);
        saved[slot]=snapshot(slot);
        assert(!sc88_parameter_blocks_submit(&blocks,slot));
    }
}
static void drain_one() {
    unsigned slot=blocks.result_slot;
    const auto& b=blocks.input[slot];
    assert(b.owner==SC88_INPUT_SUBMITTED && b.first_frame==completed_frames);
    assert(snapshot(slot)==saved[slot]);
    assert(!sc88_parameter_blocks_result_ready(&blocks,slot));
    unsigned bytes=0;
    for(unsigned n=0;n<b.frames;++n) {
        auto f=sc88_parameter_blocks_frame(&blocks,slot,n);
        auto cmd=(const uint64_t*)(blocks.commands+slot*4096+n*64);
        assert(!std::memcmp(cmd,f->command,64));
        assert(cmd[1]==completed_frames+n && (uint32_t)cmd[2]==SC88_PARAMETER_BASE+(slot*16+n)*16384);
        assert((cmd[2]>>32)==f->parameter_bytes && ((cmd[0]>>33)&1)==(cmd[1]+1==blocks.prepare.total_frames));
        bytes+=f->result_words*8;controls_count+=f->control_count;parameter_bytes+=f->parameter_bytes;
    }
    assert(bytes==b.result_bytes);result_bytes+=bytes;
    unsigned audio=blocks.audio_fill_slot;
    if(blocks.audio[audio].owner==SC88_AUDIO_DMA) {
        assert(!sc88_parameter_audio_release(&blocks,audio));
    }
    assert(!sc88_parameter_audio_begin(&blocks,audio,b.frames));
    assert(blocks.audio[audio].first_frame==completed_frames && blocks.audio[audio].last==b.last);
    assert(!sc88_parameter_audio_ready(&blocks,audio));
    assert(!sc88_parameter_audio_submit(&blocks,audio));
    completed_frames+=b.frames;++block_count;
    assert(!sc88_parameter_blocks_release(&blocks,slot));
    // Releasing the input block must leave returned audio owned by its DMA.
    assert(blocks.audio[audio].owner==SC88_AUDIO_DMA);
}
static void push(const sc88_parameter_event& event) {
    int status=sc88_parameter_blocks_event(&blocks,&event);
    if(status==0) {++waits;submit();drain_one();status=sc88_parameter_blocks_event(&blocks,&event);}
    assert(status==1);submit();
}
static void short_input(unsigned count) {
    init(count);
    for(unsigned frame=0;frame<count;++frame) {
        sc88_parameter_event e{};e.kind=5;e.frame=frame;push(e);
    }
    assert(!blocks.input_complete && blocks.input[blocks.build_slot].owner==SC88_INPUT_BUILDING);
    sc88_parameter_event end{};end.kind=8;end.frame=count;push(end);
    assert(blocks.input[blocks.build_slot].owner==SC88_INPUT_BUILDING);
    assert(!sc88_parameter_blocks_finish(&blocks));submit();
    while(completed_frames<count) drain_one();
    assert(block_count==(count+15)/16);
    for(unsigned n=0;n<2;++n) {
        unsigned slot=blocks.audio_release_slot;
        if(blocks.audio[slot].owner==SC88_AUDIO_DMA) assert(!sc88_parameter_audio_release(&blocks,slot));
    }
    assert(blocks.audio[0].owner==SC88_AUDIO_FREE && blocks.audio[1].owner==SC88_AUDIO_FREE);
}
static void negatives() {
    for(unsigned test=0;test<12;++test) {
        init(33);sc88_parameter_event e{};e.kind=5;
        for(unsigned n=0;n<16;++n) {e.frame=n;assert(sc88_parameter_blocks_event(&blocks,&e)==1);}
        int status=0;
        switch(test) {
            case 0:status=sc88_parameter_blocks_submit(&blocks,1);break;
            case 1:status=sc88_parameter_blocks_release(&blocks,0);break;
            case 2:status=sc88_parameter_blocks_result_ready(&blocks,0);break;
            case 3:status=sc88_parameter_blocks_finish(&blocks);break;
            case 4:
                assert(!sc88_parameter_blocks_submit(&blocks,0));
                status=sc88_parameter_blocks_submit(&blocks,0);break;
            case 5:status=sc88_parameter_audio_begin(&blocks,1,16);break;
            case 6:status=sc88_parameter_audio_begin(&blocks,0,17);break;
            case 7:status=sc88_parameter_audio_release(&blocks,0);break;
            case 8:
                assert(!sc88_parameter_audio_begin(&blocks,0,16));
                status=sc88_parameter_audio_submit(&blocks,0);break;
            case 9:
                assert(!sc88_parameter_blocks_submit(&blocks,0));sc88_parameter_blocks_stop(&blocks);
                assert(blocks.input[0].owner==SC88_INPUT_SUBMITTED);
                e.frame=16;status=sc88_parameter_blocks_event(&blocks,&e);break;
            case 10:e.kind=8;e.frame=33;status=sc88_parameter_blocks_event(&blocks,&e);break;
            case 11:
                assert(!sc88_parameter_audio_begin(&blocks,0,16));assert(!sc88_parameter_audio_ready(&blocks,0));
                assert(!sc88_parameter_audio_submit(&blocks,0));assert(!sc88_parameter_audio_begin(&blocks,1,16));
                status=sc88_parameter_audio_begin(&blocks,0,1);break;
        }
        assert(status<0 && blocks.fault);
    }
}
static uint32_t le32(const uint8_t *p) {
    return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
int main(int argc,char **argv) {
    negatives();for(unsigned count:{1,15,16,17,31,32,33,64,65}) short_input(count);
    std::cout<<"short_and_negative 9 12\n";
    for(int file=1;file<argc;++file) {
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);assert(input);
        sc88_parameter_reader reader;sc88_parameter_reader_init(&reader);
        assert(!sc88_parameter_reader_header(&reader,header.data(),104));init(reader.total_frames);
        uint64_t records=0;
        while(input.peek()!=std::char_traits<char>::eof()) {
            std::array<uint8_t,32> h{};input.read((char*)h.data(),32);assert(input);
            unsigned size=le32(h.data()+24);assert(size<=SC88_PARAMETER_BLOCK_BYTES);
            std::vector<uint8_t> block(size+32);std::memcpy(block.data(),h.data(),32);
            input.read((char*)block.data()+32,size);assert(input);
            assert(!sc88_parameter_reader_block(&reader,block.data(),size+32));
            sc88_parameter_event e;int status;
            while((status=sc88_parameter_reader_next(&reader,&e))>0) {push(e);++records;}
            assert(status==0);
        }
        assert(!sc88_parameter_reader_eof(&reader,0) && reader.complete);
        assert(!sc88_parameter_blocks_finish(&blocks));submit();
        while(completed_frames<reader.total_frames) drain_one();
        assert(!blocks.fault && block_count==(reader.total_frames+15)/16 && waits>0);
        std::cout<<file<<' '<<completed_frames<<' '<<block_count<<' '<<controls_count<<' '<<result_bytes
                 <<' '<<parameter_bytes<<' '<<records<<' '<<waits<<std::endl;
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(success=False, scope="PS_parameter_and_audio_block_ownership", hardware_verified=False)
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
    for name in ["sc88_parameter_blocks", "sc88_frame_prepare", "sc88_parameter_reader", "sc88_parameter_frame", "sc88_host_config"]:
        obj = OUT / (name + ".o")
        objects.append(obj)
        run([compiler / "gcc.exe", "-std=c11", *flags, "-c", ps / (name + ".c"), "-o", obj], name + ".log")
    arm = (Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm, "-std=c11", *flags, "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-c",
         ps / "sc88_parameter_blocks.c", "-o", OUT / "blocks-arm.o"], "arm-compile.log")
    (OUT / "test.cpp").write_text(SOURCE, encoding="utf-8")
    run([compiler / "g++.exe", "-std=c++17", *flags, OUT / "test.cpp", *objects, "-o", OUT / "test.exe"], "link.log")
    files = [ROOT / "build/verification/offline-player/phase-01/cases" / f"th06_{n:02d}" / "export/song.scp" for n in range(1, 8)]
    print("ARM compile passed; scanning seven complete MIDI streams through block ownership", flush=True)
    output = run([OUT / "test.exe", *files], "scan.log")
    print(output, end="", flush=True)
    rows = [line.split() for line in output.splitlines()]
    assert len(rows) == 8 and rows[0] == ["short_and_negative", "9", "12"]
    previous = json.loads((OUT.parent / "frame-prepare/summary.json").read_text(encoding="utf-8"))
    packing = json.loads((OUT.parent / "parameter-frame/summary.json").read_text(encoding="utf-8"))
    assert previous["success"] and packing["success"]
    songs = []
    for row, known, packed in zip(rows[1:], previous["songs"], packing["songs"]):
        index, frames, blocks, controls, results, parameters, records, waits = map(int, row)
        assert frames == known["frames"] and controls == known["PS_controls"]
        assert results == known["result_words"] * 8 and parameters == packed["normalized_bytes"]
        songs.append(dict(song=known["song"], frames=frames, blocks=blocks, controls=controls,
                          result_bytes=results, parameter_bytes=parameters, records=records, blocked_events=waits))
    report.update(success=True, arm_compile=True, short_lengths=9, negatives=12, songs=songs,
                  limitation="CPU ownership and immutable submitted buffers; DMA completion is simulated, not Cache/MMIO or real-time board evidence")
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
