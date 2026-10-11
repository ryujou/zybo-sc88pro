// SPDX-License-Identifier: GPL-3.0-only
#include "custom_chips/xp/xp_voice_common.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <random>
#include <stdexcept>

int main(int argc, char** argv)
{
    try
    {
        if(argc!=2) throw std::runtime_error("Usage: sc88_ramp_vectors OUTPUT_FILE");
        std::ofstream out(argv[1]); out.exceptions(std::ios::badbit|std::ios::failbit);
        std::mt19937 random(0x883);
        auto xp=std::make_unique<xpLib::XP>();
        unsigned count=0;
        for(unsigned op=0;op<4;++op) for(unsigned i=0;i<16384;++i)
        {
            const bool q4=op==2 && (i&1), parity=(i>>1)&1, curve3=(i>>2)&1;
            const uint32_t mask=q4 ? 0xfffff : 0x3ffff;
            const uint32_t boundaries[]={0,1,2,3,0x1ffff,0x20000,0x3fffe,0x3ffff};
            uint32_t current=i<256 ? boundaries[i&7] : random()&mask;
            uint32_t target=(i<256 ? boundaries[(i>>3)&7] : random()&mask)&~1u;
            uint32_t scratch=i<256 ? (i&8 ? 0xfffff : i&16 ? 0x80000 : 0x7ffff) : random()&0xfffff;
            const uint32_t rate=i<256 ? (i&32 ? 4095 : i&64 ? 1 : 0) : random()&4095;
            if(i%127==0) current=target;
            uint32_t next=current, nextScratch=scratch;
            bool terminal=false, complete=false;
            if(op==0) nextScratch=xpLib::xpInternal::calculateLinearRampStep(current,target,rate);
            else if(op==1) xpLib::xpInternal::stepLinearRamp(next,target,scratch,parity);
            else if(op==2) xpLib::xpInternal::stepLogRamp(next,target,rate,q4 ? 4 : 1,parity);
            else
            {
                xp->reset(); auto& state=xp->state(); state.highestVoice=0; state.irqConfigMask=1<<4;
                auto& v=state.voices[0];
                v.resetState_3900={true,true}; v.runtimeCache.runtimePhase=xpLib::XP::VoiceRuntimePhaseCache::running;
                v.waveControl_0000=xpLib::XP::WaveControl::waveEngineHalt;
                v.playbackStateConfig_1000=parity ? 2 : 0;
                v.ampCurrent_1e00=current; v.ampDestination_1500=target|1;
                v.ampStep_2600=scratch; v.ampRamp_1a00=rate|0x10000|(curve3 ? 0xc000 : 0x8000);
                xp->step();
                next=v.ampCurrent_1e00; nextScratch=v.ampStep_2600;
                terminal=state.interrupt; complete=!curve3 && (v.ampRamp_1a00&0x4000);
            }
            out<<op<<' '<<current<<' '<<target<<' '<<scratch<<' '<<rate<<' '<<parity<<' '<<q4<<' '<<curve3
               <<' '<<next<<' '<<nextScratch<<' '<<terminal<<' '<<complete<<'\n';
            ++count;
        }
        std::cout<<"RAMP_VECTORS_COMPLETE count="<<count<<'\n';
        return 0;
    }
    catch(const std::exception& error) { std::cerr<<error.what()<<'\n'; return 1; }
}
