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
        if(argc!=2) throw std::runtime_error("Usage: sc88_ramp_service_vectors OUTPUT_FILE");
        std::ofstream out(argv[1]); out.exceptions(std::ios::badbit|std::ios::failbit);
        auto xp=std::make_unique<xpLib::XP>(); std::mt19937 random(0x88e);
        unsigned count=0;
        for(unsigned kind=0;kind<5;++kind) for(unsigned i=0;i<8192;++i)
        {
            xp->reset(); auto& state=xp->state();
            const unsigned voice=i%64, counter=kind==0 ? 0 : kind==1 ? 2 : kind==2 ? 4 : kind==3 ? 6 : ((i&3)*2+1);
            const uint64_t frame=static_cast<uint64_t>(random())<<16 | random();
            state.highestVoice=voice; state.sampleClock=frame; state.irqStatus=random()&0xffff;
            state.irqConfigMask=i&1 ? 0x1f : random()&0x1f;
            const bool interrupt=(i&7)==0; state.interrupt=interrupt;
            auto& v=state.voices[voice];
            v.resetState_3900={true,true}; v.runtimeCache.runtimePhase=xpLib::XP::VoiceRuntimePhaseCache::running;
            v.waveControl_0000=xpLib::XP::WaveControl::waveEngineHalt;
            v.playbackStateConfig_1000=(counter+7)&7;
            v.ampCurrent_1e00=random()&0x3ffff; v.ampModCurrent_1d00=random()&0x3ffff;
            v.ampModRamp_1900=random()&0x4000; v.combinedAmp_2300=random()&0xfffff;
            v.pitchIncrement_0d00=random()&0x3ffff; v.tvfFCoefficient_2200=random()&0xfffff;
            v.runtimeCache.ampCurve2EntryPending=(i%17)==0;
            uint32_t *current,*destination,*control,*scratch,*decoded;
            uint32_t unusedScratch=random()&0xfffff;
            decoded=&v.pitchIncrement_0d00;
            switch(kind)
            {
                case 0: current=&v.ampModCurrent_1d00; destination=&v.ampModDestination_1400; control=&v.ampModRamp_1900; scratch=&unusedScratch; break;
                case 1: current=&v.tvfQCurrent_2100; destination=&v.tvfQDestination_1100; control=&v.tvfQRamp_1600; scratch=&unusedScratch; break;
                case 2: current=&v.tvfFCurrent_1c00; destination=&v.tvfFDestination_1300; control=&v.tvfFRamp_1800; scratch=&v.tvfFStep_2500; decoded=&v.tvfFCoefficient_2200; break;
                case 3: current=&v.pitchCurrent_1b00; destination=&v.pitchDestination_1200; control=&v.pitchRamp_1700; scratch=&v.pitchStep_2400; break;
                default: current=&v.ampCurrent_1e00; destination=&v.ampDestination_1500; control=&v.ampRamp_1a00; scratch=&v.ampStep_2600; break;
            }
            *current=random()&(kind==1 ? 0xfffff : 0x3ffff);
            *destination=random()&0x3ffff; *control=random()&0x3ffff; *scratch=random()&0xfffff;
            if(i%5==0) *control=(*control&0xffff)|0x10000;
            if(i%11==0) { *current=kind==1 ? ((*destination&~1u)<<2) : *destination&~1u; *control=(*control&0x0cfff)|0x10000; }
            if(i%13==0) *current=0;
            if(i%19==0) *scratch=0xfffff;
            // Source counter 6 refreshes pitch before the selected Ramp service.
            if(kind==3) *decoded=xpLib::xpInternal::decodePitch(*current);
            out<<kind<<' '<<frame<<' '<<counter<<' '<<voice<<' '<<*current<<' '<<*scratch<<' '<<*decoded<<' '<<v.combinedAmp_2300
               <<' '<<*destination<<' '<<*control<<' '<<v.ampModCurrent_1d00<<' '<<bool(v.ampModRamp_1900&0x4000)
               <<' '<<v.runtimeCache.ampCurve2EntryPending<<' '<<state.irqStatus<<' '<<state.irqConfigMask<<' '<<interrupt<<" 0 0";
            xp->step();
            out<<' '<<*current<<' '<<*scratch<<' '<<*decoded<<' '<<v.combinedAmp_2300<<' '<<*destination<<' '<<*control
               <<' '<<v.runtimeCache.ampCurve2EntryPending<<' '<<state.irqStatus<<' '<<state.interrupt<<' '<<(!interrupt && state.interrupt)<<' '<<state.irqBlockedEvent<<'\n';
            ++count;
        }
        std::cout<<"RAMP_SERVICE_VECTORS_COMPLETE count="<<count<<'\n'; return 0;
    }
    catch(const std::exception& error) { std::cerr<<error.what()<<'\n'; return 1; }
}
