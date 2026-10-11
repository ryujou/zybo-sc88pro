"""Compare PS host-to-PL writes with pristine XP, including all seven real MIDI streams."""
import os
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/host-config"
SOURCE = r'''
#include "xp.h"
extern "C" {
#include "sc88_host_config.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
using XP = xpLib::XP;
static sc88_host_config host;
static sc88_host_changes changes;
static std::unique_ptr<XP> reference;
static uint32_t actual[64][51];
static uint64_t operations, emitted;
static uint32_t expected(const XP::VoiceState& v, unsigned word) {
    switch(word) {
@FIELDS@
    default: std::abort();
    }
}
static void reset() {
    reference->reset(); sc88_host_reset(&host); std::memset(actual, 0, sizeof(actual));
}
static void operation(bool write, uint16_t address, uint8_t value=0) {
    // IRQ may arrive between the even and odd byte reads; only a fresh transaction clears it.
    reference->state().interrupt = true;
    if(write) {
        reference->hostWrite8(address, value);
        sc88_host_write(&host, address, value, &changes);
    } else {
        reference->hostRead8(address);
        sc88_host_read(&host, address, &changes);
    }
    assert(changes.count <= 128);
    for(unsigned n=0;n<changes.count;++n) {
        auto packed=changes.words[n];
        assert((packed>>60)==1 && ((packed>>32)&0xffff)==0);
        unsigned voice=(packed>>54)&63, word=(packed>>48)&63;
        assert(word<51); actual[voice][word]=(uint32_t)packed;
    }
    assert(changes.irq_acknowledge == !reference->state().interrupt);
    for(unsigned voice=0;voice<64;++voice)
        for(unsigned word=0;word<51;++word)
            if(actual[voice][word] != expected(reference->state().voices[voice],word)) {
                std::cerr << "Host mismatch operation=" << operations << " address=" << address
                          << " voice=" << voice << " word=" << word << '\n'; std::abort();
            }
    assert(host.wide_latch == reference->state().wideWriteLatch);
    assert(host.window == reference->state().voiceWindowSelect_3934);
    assert(host.highest_voice == reference->state().highestVoice);
    assert(host.irq_mask == reference->state().irqConfigMask);
    assert(!std::memcmp(host.wave_descriptors,reference->state().waveRomConfig.data(),8));
    ++operations; emitted+=changes.count;
}
static void word(uint16_t address,uint16_t value) {
    operation(true,address,(uint8_t)(value>>8)); operation(true,address+1,(uint8_t)value);
}
static uint64_t le(const uint8_t *p,unsigned count) {
    uint64_t value=0;for(unsigned n=0;n<count;++n)value|=(uint64_t)p[n]<<(n*8);return value;
}
int main(int argc,char**argv) {
    reference=std::make_unique<XP>();reset();
    // Every address, both data patterns, aliasing and partial byte writes.
    for(unsigned pass=0;pass<2;++pass)
        for(unsigned a=0;a<0x4000;++a) operation(true,(uint16_t)(a+0x4000),(uint8_t)(pass?0xff:a));
    for(unsigned v=0;v<64;++v) {
        word(0x3934,(uint16_t)v);
        for(unsigned a=0x3940;a<0x3a00;a+=2) word((uint16_t)a,(uint16_t)(a^v));
    }
    reset();
    for(unsigned a=0x3900;a<0x3908;a+=2) word((uint16_t)a,0xffff);
    operation(false,0x3907);assert(changes.count==128);
    // A repeated release read must preserve PL's independently advanced phase.
    for(unsigned v=0;v<64;++v) {
        reference->state().voices[v].runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::running;
        actual[v][49]=4;
    }
    operation(false,0x3900);assert(changes.count==0);
    for(unsigned a=0x3900;a<0x3908;a+=2) word((uint16_t)a,0);
    operation(false,0x391a);operation(false,0x391b);operation(false,0x391b);
    operation(false,0x391a);operation(true,0x500,1);operation(false,0x391b);
    word(0x3000,0x1234);word(0x2802,0xabcd);
    word(0x3400,0x4321);word(0x2902,0x1234);
    word(0x1a00,0);word(0x1a02,0x8000);assert(actual[0][48]==1);
    word(0x1a00,2);word(0x1a02,0x8000);assert(actual[0][48]==0);
    std::cout << "directed " << operations << " " << emitted << '\n';
    for(int file=1;file<argc;++file) {
        reset();operations=emitted=0;
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);
        assert(input && !std::memcmp(header.data(),"SC88PAR1",8));
        uint64_t frames=0;bool ended=false;
        while(!ended) {
            std::array<uint8_t,32> block{};input.read((char*)block.data(),32);
            assert(input && !std::memcmp(block.data(),"PBL1",4));
            unsigned size=(unsigned)le(block.data()+24,4), count=(unsigned)le(block.data()+28,4);
            assert(size<=8*1024*1024);std::vector<uint8_t> data(size);
            input.read((char*)data.data(),size);assert(input);size_t offset=0;
            for(unsigned n=0;n<count;++n) {
                assert(offset+24<=size);const uint8_t *e=data.data()+offset;
                unsigned bytes=(unsigned)le(e+20,4);assert(offset+24+bytes<=size);
                unsigned kind=e[12],target=e[14];const uint8_t *payload=e+24;
                if(kind==1) reset();
                else if((kind==2 || kind==3) && target==1) {
                    assert(bytes==(kind==2?3:2));
                    operation(kind==2,(uint16_t)le(payload,2),kind==2?payload[2]:0);
                } else if(kind==5) ++frames;
                else if(kind==8) ended=true;
                offset+=24+bytes;
            }
            assert(offset==size);
        }
        assert(input.peek()==std::char_traits<char>::eof());
        assert(frames==le(header.data()+40,8));
        std::cout << file << " " << frames << " " << operations << " " << emitted << std::endl;
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(success=False, hardware_verified=False, scope="PS_host_config_against_pristine_XP")
    (OUT / "summary.json").write_text(json.dumps(report), encoding="utf-8")
    lock = json.loads((ROOT / "reference/gearmulator-lock.json").read_text(encoding="utf-8"))
    gear = ROOT / "external/gearmulator"
    assert subprocess.check_output(["git", "-C", str(gear), "rev-parse", "HEAD"], text=True).strip() == lock["commit"]
    assert not subprocess.check_output(["git", "-C", str(gear), "status", "--porcelain"], text=True).strip()
    fields = json.loads((ROOT / "reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    cases = "\n".join(f'    case {f["word"]}: return static_cast<uint32_t>(v.{f["name"]});' for f in fields)
    (OUT / "test.cpp").write_text(SOURCE.replace("@FIELDS@", cases), encoding="utf-8")
    (OUT / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.20)
project(host_config_test LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
add_compile_definitions(CHIPS_FORCE_NO_JIT=1 _CRT_SECURE_NO_WARNINGS)
add_compile_options(/UNDEBUG /utf-8)
add_subdirectory("{gear.as_posix()}/source/ronaldo/custom_chips/xp" xp)
add_executable(host_config_test test.cpp "{ROOT.as_posix()}/software/ps/sc88_host_config.c")
target_include_directories(host_config_test PRIVATE "{ROOT.as_posix()}/software/ps")
target_link_libraries(host_config_test PRIVATE xpLib)
''', encoding="utf-8")
    def run(command, log):
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True, encoding="utf-8", errors="replace")
        (OUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
        result.check_returncode()
        return result.stdout
    run(["cmake", "-S", OUT, "-B", OUT / "build", "-G", "Visual Studio 17 2022", "-A", "x64"], "configure.log")
    run(["cmake", "--build", OUT / "build", "--config", "Release", "--parallel", "8"], "build.log")
    arm = (Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard",
         "-c", ROOT / "software/ps/sc88_host_config.c", "-o", OUT / "sc88_host_config.o"], "arm-compile.log")
    songs = [f"th06_{n:02d}" for n in range(1, 8)]
    files = [ROOT / "build/verification/offline-player/phase-01/cases" / s / "export/song.scp" for s in songs]
    for song, file in zip(songs, files):
        assert (ROOT / "private/midi/th06-demo/midi" / (song + ".mid")).is_file()
        assert file.is_file(), file
    print("Cortex-A9 compile passed; checking directed cases and all seven MIDI host streams", flush=True)
    output = run([OUT / "build/Release/host_config_test.exe", *files], "comparison.log")
    print(output, end="", flush=True)
    rows = [line.split() for line in output.splitlines()]
    assert len(rows) == 8 and rows[0][0] == "directed"
    report.update(success=True, arm_compile=True, directed_operations=int(rows[0][1]),
                  songs=[dict(song=s, frames=int(r[1]), host_operations=int(r[2]), emitted_configs=int(r[3]))
                         for s, r in zip(songs, rows[1:])],
                  limitation="Host side effects only; sample stepping, PC hooks, DMA integration and hardware are separate gates")
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
