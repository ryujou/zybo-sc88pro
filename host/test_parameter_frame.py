"""Check the ARM frame packer against the independent DMA contract and real MIDI files."""
import os
import ctypes as c
import json
from pathlib import Path
import random
import subprocess

import offline_parameter_dma as dma
from offline_parameter_format import STAGE_MASKS

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-frame"
SCAN = r'''
extern "C" {
#include "sc88_parameter_frame.h"
}
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
static uint64_t le(const uint8_t *p,unsigned count) {
    uint64_t value=0;for(unsigned n=0;n<count;++n)value|=(uint64_t)p[n]<<(8*n);return value;
}
int main(int argc,char **argv) {
    for(int file=1;file<argc;++file) {
        std::ifstream input(argv[file],std::ios::binary);assert(input);
        std::array<uint8_t,104> header{};input.read((char*)header.data(),104);
        assert(input && !std::memcmp(header.data(),"SC88PAR1",8));
        sc88_host_config host;sc88_host_reset(&host);
        sc88_host_changes changes;sc88_parameter_frame frame;
        std::array<uint8_t,16384> output{}, peak{};
        sc88_parameter_frame_begin(&frame,output.data(),0);
        uint64_t frames=0,bytes=0,peak_frame=0,configs=0,packets=0,host_ops=0;
        unsigned maximum=0,max_configs=0;bool ended=false;
        while(!ended) {
            std::array<uint8_t,32> block{};input.read((char*)block.data(),32);
            assert(input && !std::memcmp(block.data(),"PBL1",4));
            unsigned size=(unsigned)le(block.data()+24,4),count=(unsigned)le(block.data()+28,4);
            assert(size<=8*1024*1024);std::vector<uint8_t> data(size);
            input.read((char*)data.data(),size);assert(input);size_t offset=0;
            for(unsigned n=0;n<count;++n) {
                assert(offset+24<=size);const uint8_t *e=data.data()+offset;
                unsigned length=(unsigned)le(e+20,4),kind=e[12],target=e[14];
                assert(offset+24+length<=size && le(e,8)==frames);const uint8_t *p=e+24;
                if(kind==1) {assert(frames==0);sc88_host_reset(&host);}
                else if((kind==2 || kind==3) && target==1) {
                    ++host_ops;
                    if(kind==2) sc88_host_write(&host,(uint16_t)le(p,2),p[2],&changes);
                    else sc88_host_read(&host,(uint16_t)le(p,2),&changes);
                    if(changes.count) assert(!sc88_parameter_frame_configs(&frame,&changes));
                } else if(kind==6 || kind==7) {
                    uint32_t values[22];unsigned mask=kind==6?(unsigned)le(e+16,4):0;
                    for(unsigned i=0;i<length/4;++i) values[i]=(uint32_t)le(p+i*4,4);
                    int result=sc88_parameter_frame_hook(&frame,e[15],e[13],mask,values,kind==7?p[0]:-1);
                    if(result) {std::cerr<<"hook failure file="<<file<<" frame="<<frames<<'\n';return 1;}
                } else if(kind==5) {
                    unsigned size=sc88_parameter_frame_finish(&frame);
                    if(!size) {std::cerr<<"finish failure file="<<file<<" frame="<<frames<<'\n';return 1;}
                    assert(size<=16384 && !(size&31));
                    if(size>maximum) {maximum=size;peak_frame=frames;peak=output;}
                    if(frame.configs>max_configs) max_configs=frame.configs;
                    bytes+=size;configs+=frame.configs;packets+=frame.packets;
                    sc88_parameter_frame_begin(&frame,output.data(),++frames);
                } else if(kind==8) ended=true;
                offset+=24+length;
            }
            assert(offset==size);
        }
        assert(input.peek()==std::char_traits<char>::eof() && frames==le(header.data()+40,8));
        std::ofstream saved(std::to_string(file)+"-peak.dma",std::ios::binary);
        saved.write((char*)peak.data(),maximum);assert(saved);
        std::cout<<file<<' '<<frames<<' '<<bytes<<' '<<maximum<<' '<<peak_frame<<' '
                 <<max_configs<<' '<<configs<<' '<<packets<<' '<<host_ops<<std::endl;
    }
}
'''


class Frame(c.Structure):
    _fields_ = [("data", c.POINTER(c.c_uint8))] + [(n, c.c_uint) for n in
                ["words", "configs", "packets", "fault", "finished", "pending", "voice", "stage", "mask", "terminal"]] + [("values", c.c_uint32 * 22)]


class Changes(c.Structure):
    _fields_ = [("words", c.c_uint64 * 128), ("count", c.c_uint), ("irq_acknowledge", c.c_uint)]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(success=False, hardware_verified=False, scope="PS_SC88DMA1_frame_packer")
    (OUT / "summary.json").write_text(json.dumps(report), encoding="utf-8")
    def run(command, log):
        result = subprocess.run(list(map(str, command)), cwd=OUT, capture_output=True, text=True)
        (OUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
        result.check_returncode()
        return result.stdout
    compiler = (Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin")
    source = ROOT / "software/ps"
    sources = [source / (n + ".c") for n in ["sc88_parameter_frame", "sc88_host_config"]]
    flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
    run([compiler / "gcc.exe", *flags, "-shared", *sources, "-o", OUT / "packer.dll"], "compile.log")
    arm = (Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm, *flags, "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-c", sources[0],
         "-o", OUT / "sc88_parameter_frame.o"], "arm-compile.log")
    lib = c.CDLL(str(OUT / "packer.dll"))
    begin, config, hook, finish = [getattr(lib, "sc88_parameter_frame_" + n) for n in ["begin", "configs", "hook", "finish"]]
    begin.argtypes = [c.POINTER(Frame), c.POINTER(c.c_uint8), c.c_uint64]
    config.argtypes = [c.POINTER(Frame), c.POINTER(Changes)]
    hook.argtypes = [c.POINTER(Frame), c.c_uint, c.c_uint, c.c_uint, c.POINTER(c.c_uint32), c.c_int]
    finish.argtypes = [c.POINTER(Frame)]
    def start(number=0):
        f, buffer = Frame(), (c.c_uint8 * 16384)()
        begin(c.byref(f), buffer, number)
        return f, buffer
    def add_config(f, configs):
        for first in range(0, len(configs), 128):
            batch = configs[first:first+128]
            changes = Changes(count=len(batch))
            for n, (v, w, value) in enumerate(batch):
                changes.words[n] = 1 << 60 | v << 54 | w << 48 | value
            if config(c.byref(f), c.byref(changes)): return -1
        return 0
    def add_hook(f, voice, stage, mask, selected, terminal=-1):
        values = (c.c_uint32 * len(selected))(*selected)
        return hook(c.byref(f), voice, stage, mask, values, terminal)
    rng = random.Random(88)
    for case in range(512):
        number = (1 << 40) + case
        f, buffer = start(number)
        configs = []
        for _ in range(rng.randrange(0, 321)):
            word = rng.randrange(51)
            configs.append((rng.randrange(64), word, rng.randrange(1 << dma.WIDTHS[word])))
        assert not add_config(f, configs)
        packets = []
        for key in sorted(rng.sample(range(256), rng.randrange(0, 20))):
            voice, stage = key // 4, key % 4 + 1
            mask = rng.getrandbits(22) & STAGE_MASKS[stage]
            terminal = rng.randrange(5) if stage == 4 and rng.randrange(2) else -1
            if not mask and terminal == -1: continue
            values = [0] * 22
            for n in range(22):
                if mask >> n & 1:
                    values[n] = rng.randrange(1 << (1 if n == 21 else 20 if n >= 15 else 18))
                    if 6 <= n <= 10: values[n] &= ~0x20000
            packets.append((voice, stage, mask, terminal, values))
            selected = [v for n, v in enumerate(values) if mask >> n & 1]
            if terminal >= 0 and case % 2:
                assert not add_hook(f, voice, stage, 0, [], terminal)
            if mask: assert not add_hook(f, voice, stage, mask, selected)
            if terminal >= 0 and not case % 2:
                assert not add_hook(f, voice, stage, 0, [], terminal)
        size = finish(c.byref(f));assert size
        packed = bytes(buffer[:size])
        assert packed == dma.encode(number, configs, packets)
        assert dma.decode(packed) == (number, configs, packets)
    negatives = [(64,1,1,[0],-1), (0,0,1,[0],-1), (0,5,1,[0],-1), (0,1,2,[0],-1),
                 (0,1,1,[1<<18],-1), (0,4,1<<15,[1<<20],-1), (0,4,1<<21,[2],-1),
                 (0,4,1<<10,[0x20000],-1), (0,1,0,[],0), (0,4,0,[],5), (0,4,0,[],-1)]
    for args in negatives:
        f, buffer = start();assert add_hook(f, *args) and not finish(c.byref(f))
    for duplicate in [False, True]:
        f, buffer = start();assert not add_hook(f,1,4,1,[0])
        assert add_hook(f,1 if duplicate else 0,4,1,[0]) and not finish(c.byref(f))
    f, buffer = start();assert not add_hook(f,0,4,0,[],0)
    assert add_hook(f,0,4,0,[],1) and not finish(c.byref(f))
    f, buffer = start();assert not add_hook(f,0,1,1,[0])
    assert add_config(f,[(0,0,0)]) and not finish(c.byref(f))
    f, buffer = start();assert not add_config(f,[(0,0,0)]*2044)
    assert finish(c.byref(f))==16384 and not finish(c.byref(f))
    for extra_hook in [False, True]:
        f, buffer = start();assert not add_config(f,[(0,0,0)]*2044)
        if extra_hook: assert not add_hook(f,0,1,1,[0])
        else: assert add_config(f,[(0,0,0)])
        assert not finish(c.byref(f))
    (OUT / "scan.cpp").write_text(SCAN, encoding="utf-8")
    objects=[]
    for s in sources:
        obj=OUT/(s.stem+"-native.o");objects.append(obj)
        run([compiler/"gcc.exe", *flags, "-c", s, "-o", obj], s.stem+".log")
    run([compiler/"g++.exe", "-std=c++17", "-O2", "-I", source, OUT/"scan.cpp", *objects, "-o", OUT/"scan.exe"], "scan-build.log")
    files = [ROOT/"build/verification/offline-player/phase-01/cases"/f"th06_{n:02d}"/"export/song.scp" for n in range(1,8)]
    for n, file in enumerate(files, 1):
        assert file.is_file() and (ROOT/"private/midi/th06-demo/midi"/f"th06_{n:02d}.mid").is_file()
    print("512 byte-exact fixtures and malformed/capacity checks passed; scanning seven full MIDI files", flush=True)
    output = run([OUT/"scan.exe", *files], "scan.log");print(output, end="", flush=True)
    rows = [list(map(int,line.split())) for line in output.splitlines()]
    assert len(rows)==7
    songs=[]
    host_report=json.loads((ROOT/"build/verification/offline-player/phase-04/host-config/summary.json").read_text(encoding="utf-8"))
    assert host_report["success"] and len(host_report["songs"])==7
    for row, known in zip(rows,host_report["songs"]):
        index, frames, total, maximum, peak, max_configs, configs, packets, host_ops=row
        assert (frames,configs,host_ops)==(known["frames"],known["emitted_configs"],known["host_operations"])
        dma.decode((OUT/f"{index}-peak.dma").read_bytes(),peak)
        songs.append(dict(song=f"th06_{index:02d}",frames=frames,normalized_bytes=total,peak_bytes=maximum,
                          peak_frame=peak,max_frame_configs=max_configs,configs=configs,packets=packets))
    report.update(success=True,arm_compile=True,byte_exact_cases=512,negative_cases=18,songs=songs,
                  limitation="Frame encoding and capacity only; PS-owned effect/global events, streaming decode, real-time deadlines and hardware are separate")
    (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__ == "__main__":
    main()
