// SPDX-License-Identifier: GPL-3.0-only
#include "offline_player/parameter.h"
#include "custom_chips/xp/xp_voice_common.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>

using XP=xpLib::XP;
namespace fs=std::filesystem;

void fixture(XP& xp, unsigned test)
{
    xp.reset(); auto& s=xp.state(); s.highestVoice=3; s.irqConfigMask=0x13f;
    for(unsigned i=0;i<4;++i)
    {
        auto& v=s.voices[i];
        v.resetState_3900={true,true}; v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::running;
        v.runtimeCache.waveSampleFormat=XP::WaveSampleFormatCache::fceDpcmExponent0;
        v.waveControl_0000=XP::WaveControl::irqEnable|XP::WaveControl::fceDpcmExponent0OrProducerLive;
        v.sampleLoop_0200=0; v.sampleEnd_0300=31; v.pitchIncrement_0d00=0x18000;
        v.playbackStateConfig_1000=0x30006; v.ampDestination_1500=1; v.ampRamp_1a00=0x10000;
        v.pitchDestination_1200=v.tvfFDestination_1300=v.tvfQDestination_1100=v.ampModDestination_1400=1;
        v.pitchRamp_1700=v.tvfFRamp_1800=v.tvfQRamp_1600=v.ampModRamp_1900=0x20000;
        v.tvfFCoefficient_2200=0x20000; v.tvfQCurrent_2100=0x10000; v.tvaGain_2700=0x7000;
        for(unsigned j=0;j<8;++j) v.waveCircularBuffer_0800[j]=static_cast<uint16_t>(j*3+1);
    }
    auto& v=s.voices[0];
    switch(test)
    {
    case 0: v.waveControl_0000|=XP::WaveControl::muteRequest; break;
    case 1: v.pitchIncrement_0d00=0x30000; break;
    case 2: s.interrupt=true; s.irqStatus=0x0105; break;
    case 3: s.irqConfigMask&=~(1u<<5); break;
    case 4: s.irqConfigMask=0; v.ampRamp_1a00=0; break;
    case 5: v.waveControl_0000|=XP::WaveControl::muteRequest; s.voices[1].waveControl_0000|=XP::WaveControl::loopEventInhibit; break;
    case 6: v.filterConfig_2000=0x1010; break;
    case 7: v.waveControl_0000|=XP::WaveControl::reverse|XP::WaveControl::alternateLoop; v.sampleLoop_0200=1; v.sampleEnd_0300=3; v.sampleCurrent_0100=1; break;
    case 8: v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::initialize; v.pitchRamp_1700=0x4005; v.pitchCurrent_1b00=v.pitchDestination_1200=0x14001; break;
    case 9: v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::starting; v.tvfFRamp_1800=0x4005; v.tvfFCurrent_1c00=0x8000; v.tvfFDestination_1300=0x14001; break;
    case 10: v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::parked; break;
    case 11: v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::preload; break;
    case 12: v.playbackStateConfig_1000=0x30005; v.pitchCurrent_1b00=0x14000; v.pitchDestination_1200=0x14001; break;
    case 13: v.combinedAmp_2300=0x70000; v.ampCurrent_1e00=0x18000; break;
    case 14: v.playbackStateConfig_1000=0x30005; v.pitchRamp_1700=0x10000; s.irqConfigMask=1u<<2; break;
    case 15: v.playbackStateConfig_1000=0x30001; v.tvfQRamp_1600=0x10000; v.tvfQCurrent_2100=0; s.irqConfigMask=1; break;
    case 16: v.playbackStateConfig_1000=0x30003; v.tvfFRamp_1800=0x10000; s.irqConfigMask=1u<<1; break;
    case 17: v.playbackStateConfig_1000=0x30007; v.ampModRamp_1900=0x10000; s.irqConfigMask=1u<<3; break;
    case 18: v.ampRamp_1a00=0x30000; s.irqConfigMask=1u<<4; break;
    case 19: v.waveControl_0000|=XP::WaveControl::muteRequest; s.irqConfigMask&=~(1u<<8); break;
    case 20: v.ampRamp_1a00=0x18010; v.ampCurrent_1e00=2; v.ampStep_2600=0xfffff; s.irqConfigMask=1u<<4; break;
    case 21: v.ampRamp_1a00=0x1c010; v.ampStep_2600=0xfffff; s.irqConfigMask=1u<<4; break;
    default: throw std::runtime_error("Unknown fixture");
    }
}

void observe(std::ofstream& out, const XP& xp)
{
    const auto& s=xp.state();
    const auto word=[&](uint64_t v){ for(unsigned i=0;i<8;++i) out.put(static_cast<char>(v>>(8*i))); };
    word(s.sampleClock); word(s.interrupt); word(s.irqStatus); word(s.irqBlockedEvent); word(s.irqConfigMask); word(s.readbackLatch);
    for(unsigned i=0;i<4;++i)
    {
        const auto& v=s.voices[i]; for(auto value:sc88param::values(v)) word(value);
        word(v.tvfQRamp_1600); word(v.pitchRamp_1700); word(v.tvfFRamp_1800); word(v.ampModRamp_1900); word(v.ampRamp_1a00);
        word(v.waveControl_0000); word(v.sampleCurrent_0100); word(v.sampleLoop_0200); word(v.sampleEnd_0300); word(v.waveFetchState_0400);
        for(auto sample:v.waveCircularBuffer_0800) word(sample);
        word(v.dpcmAccumulator_0c00); word(v.addressFraction_0e00); word(v.playbackStateConfig_1000); word(v.tvaGain_2700);
        word(v.filterBp_2800); word(v.filterLp_2900); word(v.filterOutput_2a00); word(static_cast<uint8_t>(v.runtimeCache.runtimePhase)); word(static_cast<uint8_t>(v.runtimeCache.waveSampleFormat));
    }
}

int main(int argc,char** argv)
{
    try
    {
        if(argc!=3) throw std::runtime_error("Usage: offline_irq_probe CASE OUTPUT_DIR");
        const unsigned test=std::stoul(argv[1]); const fs::path out(argv[2]); fs::create_directories(out);
        auto xp=std::make_unique<XP>(); auto lsp=std::make_unique<lspLib::LSPDispatcher>();
        std::array<uint8_t,512> waves{}; for(size_t i=0;i<waves.size();++i) waves[i]=static_cast<uint8_t>((i*37+19)&127);
        xp->mapWaveRom(0,waves.data(),waves.size(),XP::PhysicalWaveRomWidth::bits16);
        fixture(*xp,test);
        constexpr const char* commit="9af8bb05bcef2994b5dbb60c5c028e978a72aecb";
#if SC88_PROBE_MODE == 1
        sc88param::Writer writer(out/"song.scp",1,63,commit); sc88param::active=&writer; writer.reset(*xp,*lsp,false);
#elif SC88_PROBE_MODE == 2
        sc88param::Reader reader(out/"song.scp",commit); sc88param::replay=&reader;
        if(reader.take().kind!=sc88param::Reset) throw std::runtime_error("Missing fixture RESET");
#endif
        std::ofstream observations(out/(SC88_PROBE_MODE==0 ? "reference.state" : SC88_PROBE_MODE==1 ? "export.state" : "replay.state"),std::ios::binary);
        observations.exceptions(std::ios::badbit|std::ios::failbit);
        for(unsigned frame=0;frame<64;++frame)
        {
            if(frame && frame%8==0)
            {
#if SC88_PROBE_MODE == 2
                const auto event=reader.take();
                if(event.kind!=sc88param::Read || event.payload!=std::vector<uint8_t>{0x1a,0x39}) throw std::runtime_error("Fixture ACK mismatch");
#elif SC88_PROBE_MODE == 1
                sc88param::access(false,1,0x391a,0);
#endif
                xp->hostRead8(0x391a);
            }
            xp->step(); observe(observations,*xp);
#if SC88_PROBE_MODE == 1
            writer.frame(*xp,*lsp,false);
#elif SC88_PROBE_MODE == 2
            if(reader.take().kind!=sc88param::Frame) throw std::runtime_error("Unconsumed/mispositioned control event");
            reader.nextFrame();
#endif
        }
#if SC88_PROBE_MODE == 1
        writer.finish(*xp,*lsp,false); sc88param::active=nullptr;
#elif SC88_PROBE_MODE == 2
        if(reader.take().kind!=sc88param::End) throw std::runtime_error("Missing fixture END");
        reader.finish(); sc88param::replay=nullptr;
#endif
        std::cout<<"SC88_OFFLINE_IRQ_PROBE_COMPLETE case="<<test<<" frames=64 mode="<<SC88_PROBE_MODE<<'\n'; return 0;
    }
    catch(const std::exception& error) { std::cerr<<error.what()<<'\n'; return 1; }
}
