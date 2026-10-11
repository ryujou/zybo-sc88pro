// SPDX-License-Identifier: GPL-3.0-only
#include "parameter_voice_probe.h"
#include "custom_chips/xp/xp_voice_common.h"
#include <filesystem>
#include <iostream>
#include <memory>
#include <vector>

using XP=xpLib::XP;
namespace fs=std::filesystem;
// FIXED_IRQ_FIXTURE

int main(int argc,char** argv)
{
    try
    {
        if(argc!=2) throw std::runtime_error("Usage: parameter_irq_vectors OUT_DIR");
        const fs::path out(argv[1]);fs::create_directories(out);
        std::vector<uint8_t> waves(512);
        for(size_t i=0;i<waves.size();++i) waves[i]=static_cast<uint8_t>((i*37+19)&127);
        std::ofstream image(out/"decoded-wave.bin",std::ios::binary);
        image.write(reinterpret_cast<const char*>(waves.data()),waves.size());
        std::vector<char> zeros((20<<20)-waves.size());image.write(zeros.data(),zeros.size());image.close();
        for(unsigned test=0;test<22;++test)
        {
            const auto path=out/("irq_"+std::to_string(test));fs::create_directories(path);
            auto xp=std::make_unique<XP>();xp->mapWaveRom(0,waves.data(),waves.size(),XP::PhysicalWaveRomWidth::bits16);
            fixture(*xp,test);
            std::ofstream initial(path/"initial.csv"),expected(path/"expected.csv"),commands(path/"commands.csv"),parameters(path/"parameters.csv");
            std::ofstream reads(path/"rom-reads.csv"),stages(path/"stages.csv");
            sc88voice::csvHeader(initial,xp->state(),0,4);sc88voice::csvRow(initial,xp->state(),0,0,4);
            sc88voice::csvHeader(expected,xp->state(),0,4);
            commands<<"command_voice,pair,accepted,";sc88voice::csvHeader(commands,xp->state(),0,4);
            sc88voice::romHeader(reads);sc88voice::stageHeader(stages);sc88rtlparam::open(parameters);
            sc88voice::observedVoiceCount=4;sc88voice::observedVoices=xp->state().voices.data();
            sc88voice::romReads=&reads;sc88voice::stages=&stages;sc88rtlparam::commands=&commands;
            for(unsigned frame=0;frame<64;++frame)
            {
                if(frame && frame%8==0) xp->hostRead8(0x391a);
                sc88voice::observedFrame=frame;xp->step();sc88voice::csvRow(expected,xp->state(),frame,0,4);
            }
            sc88voice::romReads=nullptr;sc88voice::stages=nullptr;sc88rtlparam::output=nullptr;sc88rtlparam::commands=nullptr;
        }
        std::cout<<"SC88_PARAMETER_IRQ_VECTORS_COMPLETE cases=22 frames=1408\n";
        return 0;
    }
    catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
