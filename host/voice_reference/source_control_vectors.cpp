// SPDX-License-Identifier: GPL-3.0-only
#include "custom_chips/xp/xp_voice_common.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <random>
#include <stdexcept>

int main(int argc,char** argv)
{
    try
    {
        if(argc!=2) throw std::runtime_error("Usage: sc88_source_control_vectors OUTPUT_FILE");
        std::ofstream out(argv[1]);out.exceptions(std::ios::badbit|std::ios::failbit);
        auto xp=std::make_unique<xpLib::XP>();std::mt19937 random(0x88c);
        unsigned count=0;
        for(unsigned phase=0;phase<5;++phase) for(unsigned i=0;i<8192;++i)
        {
            xp->reset();auto& state=xp->state();auto& v=state.voices[63];
            state.highestVoice=63;state.sampleClock=uint64_t(random())<<16|random();
            v.resetState_3900={true,true};
            v.runtimeCache.runtimePhase=static_cast<xpLib::XP::VoiceRuntimePhaseCache>(phase);
            v.waveControl_0000=xpLib::XP::WaveControl::waveEngineHalt;
            v.playbackStateConfig_1000=i&7;
            v.pitchCurrent_1b00=random()&0x3ffff;v.tvfFCurrent_1c00=random()&0x3ffff;v.ampCurrent_1e00=random()&0x3ffff;
            v.pitchDestination_1200=random()&0x3ffff;v.tvfFDestination_1300=random()&0x3ffff;v.ampDestination_1500=random()&0x3ffff;
            v.pitchRamp_1700=random()&0x3ffff;v.tvfFRamp_1800=random()&0x3ffff;v.ampRamp_1a00=random()&0x3ffff;
            v.pitchIncrement_0d00=random()&0x3ffff;v.tvfFCoefficient_2200=random()&0xfffff;
            if(i%5==0) {v.pitchRamp_1700&=0x0ffff;v.tvfFRamp_1800&=0x0ffff;}
            if(i%7==0) {v.pitchRamp_1700=0x4005;v.pitchDestination_1200=v.pitchCurrent_1b00;}
            if(i%11==0) {v.tvfFRamp_1800=0x4005;v.tvfFDestination_1300=v.tvfFCurrent_1c00;}
            if(i%13==0) {v.ampRamp_1a00=0x4005;v.ampDestination_1500=v.ampCurrent_1e00;}
            // Running vectors isolate the source refresh; the separately tested Ramp service is held.
            if(phase==4)
            {
                v.pitchRamp_1700=(v.pitchRamp_1700&0xffff)|0x20000;v.tvfFRamp_1800=(v.tvfFRamp_1800&0xffff)|0x20000;v.ampRamp_1a00=0x20000;
                // Slot 4 refreshes F even when held; begin with that coefficient to isolate the source stage.
                if((i&7)==3) v.tvfFCoefficient_2200=(xpLib::xpInternal::decodePitch(v.tvfFCurrent_1c00)<<2)&0xfffff;
            }
            out<<state.sampleClock<<' '<<phase<<' '<<(i&7)<<' '<<v.pitchCurrent_1b00<<' '<<v.tvfFCurrent_1c00<<' '<<v.ampCurrent_1e00
               <<' '<<v.pitchDestination_1200<<' '<<v.tvfFDestination_1300<<' '<<v.ampDestination_1500
               <<' '<<v.pitchRamp_1700<<' '<<v.tvfFRamp_1800<<' '<<v.ampRamp_1a00<<' '<<v.pitchIncrement_0d00<<' '<<v.tvfFCoefficient_2200;
            xp->step();
            out<<' '<<v.pitchCurrent_1b00<<' '<<v.tvfFCurrent_1c00<<' '<<v.ampCurrent_1e00<<' '<<v.pitchIncrement_0d00<<' '<<v.tvfFCoefficient_2200<<'\n';
            ++count;
        }
        std::cout<<"SOURCE_CONTROL_VECTORS_COMPLETE count="<<count<<'\n';return 0;
    }
    catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
