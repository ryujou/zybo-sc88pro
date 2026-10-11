// SPDX-License-Identifier: GPL-3.0-only
#include "voice_probe.h"
#include "custom_chips/xp/xp_voice_common.h"
#include "custom_chips/xp/xp_dsp_ops.h"
#include <filesystem>
#include <iostream>
#include <memory>
#include <vector>

namespace fs=std::filesystem;
using XP=xpLib::XP;
constexpr unsigned frameCount=128, chipBytes=1<<22;

XP::VoiceState seed(unsigned index, const std::string& name)
{
    XP::VoiceState v{};
    const unsigned format=index%3;
    v.waveControl_0000=(index%5)<<4;
    if(format==1) v.waveControl_0000|=XP::WaveControl::fceDpcmExponent0OrProducerLive;
    if(format==2) v.waveControl_0000|=XP::WaveControl::ldpcmFormat;
    v.sampleCurrent_0100=0x40030+index*0x1000;
    v.sampleLoop_0200=v.sampleCurrent_0100+0x10;
    v.sampleEnd_0300=v.sampleCurrent_0100+0x7f;
    v.pitchCurrent_1b00=v.pitchDestination_1200=0x38000;
    v.tvfFCurrent_1c00=v.tvfFDestination_1300=0x30000;
    v.ampCurrent_1e00=v.ampDestination_1500=0x18000;
    v.ampModCurrent_1d00=v.ampModDestination_1400=0x1fffe;
    v.tvfQCurrent_2100=0x20000; v.tvfQDestination_1100=0x8000;
    v.pitchRamp_1700=v.tvfFRamp_1800=v.tvfQRamp_1600=v.ampModRamp_1900=v.ampRamp_1a00=0x20000;
    v.tvaGain_2700=0x6000; v.combinedAmp_2300=xpLib::xpInternal::combineAmp(v);
    v.resetState_3900={true,true}; v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::preload;
    for(unsigned send=0;send<4;++send) v.mixer_3a00[send]=static_cast<uint16_t>(((127+index*31+send*199)%1024)<<6)|((index*4+send)%64);
    if(name=="silence") return {};
    if(name=="sync_loop" || name=="endpoint_q" || name=="endpoint_f" || name=="pairs_endpoint")
    {
        v.waveControl_0000=(index%5)<<4;
        v.sampleCurrent_0100=v.sampleLoop_0200=v.sampleEnd_0300=index*0x1000;
        v.pitchCurrent_1b00=v.pitchDestination_1200=0x3ffff;
    }
    if(name=="endpoint_q" || name=="pairs_endpoint") {v.tvfQRamp_1600=0x3ff; v.tvfQDestination_1100=0x3fffe;}
    if(name=="endpoint_f") {v.tvfFRamp_1800=0x3ff; v.tvfFDestination_1300=0x3fffe;}
    if((name=="mixed_pairs" || name=="pairs_endpoint") && index%2==0)
        v.filterConfig_2000=((index/2%9+1)<<12)|XP::FilterConfig::pairRole|(1<<10)|(2<<8)|(3<<6);
    if(name=="reverse_loop") {v.waveControl_0000|=XP::WaveControl::reverse; std::swap(v.sampleCurrent_0100,v.sampleEnd_0300);}
    if(name=="unmapped") v.waveControl_0000=(v.waveControl_0000&~0x70)|0x70;
    if(name=="irq_contention") {v.waveControl_0000|=XP::WaveControl::irqEnable|XP::WaveControl::muteRequest;}
    return v;
}

int main(int argc,char** argv)
{
    try
    {
        if(argc!=2) throw std::runtime_error("Usage: sc88_multivoice_vectors OUT_DIR");
        const fs::path out=argv[1]; fs::create_directories(out);
        std::vector<uint8_t> rom(5*chipBytes);
        for(size_t i=0;i<rom.size();++i) rom[i]=static_cast<uint8_t>((i*73+(i>>7)*19+0x35)^(i>>13));
        const std::vector<std::string> names={"silence","locality","random_jumps","sync_loop","endpoint_q","endpoint_f","mixed_pairs","pairs_endpoint","reverse_loop","unmapped","irq_contention","mixer_extremes"};
        std::ofstream manifest(out/"manifest.csv"); manifest.exceptions(std::ios::badbit|std::ios::failbit);
        manifest<<"case,voices,frames,rom_reads\n";
        for(unsigned count:{1,8,32,64}) for(const auto& name:names)
        {
            const auto id=std::to_string(count)+"_"+name;
            const auto path=out/id; fs::create_directories(path);
            auto xp=std::make_unique<XP>(); xp->reset(); auto& state=xp->state(); state.highestVoice=count-1;
            state.irqConfigMask=0x1ff;
            for(unsigned cs=0;cs<5;++cs) {xp->mapWaveRom(cs,rom.data()+cs*chipBytes,chipBytes,XP::PhysicalWaveRomWidth::bits16); state.waveRomConfig[cs]=1;}
            for(unsigned voice=0;voice<count;++voice) state.voices[voice]=seed(voice,name);
            auto open=[&](const char* file) {std::ofstream s(path/file); s.exceptions(std::ios::badbit|std::ios::failbit); return s;};
            auto initial=open("initial.csv"), expected=open("expected.csv"), events=open("events.csv"), reads=open("rom-reads.csv"), sends=open("sends.csv"), mix=open("mix.csv"), schedule=open("schedule.csv");
            sc88voice::csvHeader(initial,state,0,count); sc88voice::csvRow(initial,state,0,0,count);
            sc88voice::csvHeader(expected,state,0,count); sc88voice::romHeader(reads);
            events<<"frame,event,value\n";
            sends<<"frame,voice,send,slot,destination,contribution\n";
            mix<<"frame,bank,seen"; for(unsigned cell=0;cell<64;++cell) mix<<",cell["<<cell<<']'; mix<<'\n';
            schedule<<"frame,voice,pair\n";
            sc88voice::observedVoices=state.voices.data(); sc88voice::observedVoiceCount=count;
            sc88voice::romReads=&reads; sc88voice::romReadCount=0; sc88voice::mixerSends=&sends;
            uint32_t random=0x13579bdf;
            for(unsigned frame=0;frame<frameCount;++frame)
            {
                sc88voice::observedFrame=frame;
                auto change=[&](unsigned voice,const char* field,auto& target,auto value) {
                    target=value; events<<frame<<",voice["<<voice<<"]."<<field<<','<<uint64_t(value)<<'\n';
                };
                for(unsigned voice=0;voice<count;++voice)
                {
                    auto& v=state.voices[voice];
                    if(name=="random_jumps" && frame%8==0)
                    {
                        random^=random<<13; random^=random>>17; random^=random<<5;
                        const auto addr=(random&0xfffff)&~1u;
                        change(voice,"sampleCurrent_0100",v.sampleCurrent_0100,addr);
                        change(voice,"sampleLoop_0200",v.sampleLoop_0200,addr);
                        change(voice,"sampleEnd_0300",v.sampleEnd_0300,(addr+127)&0xfffffu);
                    }
                    if(name=="mixer_extremes")
                    {
                        constexpr uint32_t outputs[]={0x7fffff,0x7fffff,0x800000,0xffffff,0,1,511,0xfffe01};
                        change(voice,"filterOutput_2a00",v.filterOutput_2a00,outputs[(frame+voice)%8]);
                        for(unsigned send=0;send<4;++send)
                        {
                            const unsigned level=frame%5==0 ? 0 : send==3 ? 1 : 1023;
                            const auto field="mixer_3a00["+std::to_string(send)+"]";
                            change(voice,field.c_str(),v.mixer_3a00[send],static_cast<uint16_t>((level<<6)|(frame%4==0 ? 63 : (frame/4)%64)));
                        }
                    }
                }
                if(name=="irq_contention" && frame%8==0) {state.interrupt=false; events<<frame<<",interrupt,0\n";}
                for(unsigned voice=0;voice<count;++voice)
                {
                    const auto config=state.voices[voice].filterConfig_2000;
                    const auto structure=(config&XP::FilterConfig::structureMask)>>12;
                    const bool paired=voice%2==0 && voice+1<count && (config&XP::FilterConfig::pairRole) && structure>=1 && structure<=9;
                    schedule<<frame<<','<<voice<<','<<paired<<'\n'; if(paired) ++voice;
                }
                const auto bank=state.dsp.state().iramSelPhase;
                xp->step(); sc88voice::csvRow(expected,state,frame,0,count);
                const auto& dsp=state.dsp.state(); mix<<frame<<','<<unsigned(bank)<<','<<dsp.mixerInitialized;
                for(auto value:bank ? dsp.iram2 : dsp.iram1) mix<<','<<xpLib::dspOps::signExtend(value,24);
                mix<<'\n';
            }
            sc88voice::romReads=nullptr; sc88voice::mixerSends=nullptr; sc88voice::observedVoices=nullptr; sc88voice::observedVoiceCount=2;
            manifest<<id<<','<<count<<','<<frameCount<<','<<sc88voice::romReadCount<<'\n';
            std::cout<<id<<": frames="<<frameCount<<" reads="<<sc88voice::romReadCount<<'\n';
        }
        return 0;
    }
    catch(const std::exception& e) {std::cerr<<e.what()<<'\n'; return 1;}
}
