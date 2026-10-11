// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "voice_probe.h"
#include <array>

namespace sc88rtlparam
{
using XP = xpLib::XP;
using Values = std::array<uint32_t,22>;
inline std::ostream* output = nullptr;
inline std::ostream* commands = nullptr;
inline int candidate = -1;
inline Values values(const XP::VoiceState& v)
{
    return {v.pitchIncrement_0d00,
        v.tvfQDestination_1100,v.pitchDestination_1200,v.tvfFDestination_1300,v.ampModDestination_1400,v.ampDestination_1500,
        v.tvfQRamp_1600&~0x20000u,v.pitchRamp_1700&~0x20000u,v.tvfFRamp_1800&~0x20000u,v.ampModRamp_1900&~0x20000u,v.ampRamp_1a00&~0x20000u,
        v.pitchCurrent_1b00,v.tvfFCurrent_1c00,v.ampModCurrent_1d00,v.ampCurrent_1e00,
        v.tvfQCurrent_2100,v.tvfFCoefficient_2200,v.combinedAmp_2300,v.pitchStep_2400,v.tvfFStep_2500,v.ampStep_2600,
        v.runtimeCache.ampCurve2EntryPending};
}
inline void open(std::ostream& stream)
{
    output=&stream;
    stream<<"frame,voice,stage,mask,terminal";
    for(unsigned i=0;i<22;++i) stream<<",value"<<i;
    stream<<'\n';
}
inline void command(const XP::State& state,size_t voice,bool paired,bool accepted)
{
    if(!commands) return;
    *commands<<voice<<','<<paired<<','<<accepted<<',';
    sc88voice::csvRow(*commands,state,sc88voice::observedFrame,0,4);
}
template<class F> void compute(unsigned stage,size_t voice,XP::VoiceState& state,F&& calculation)
{
    const auto before=values(state);
    candidate=-1;
    calculation();
    if(!output) return;
    const auto after=values(state);
    uint32_t mask=0;
    for(unsigned i=0;i<22;++i) if(before[i]!=after[i]) mask|=1u<<i;
    *output<<sc88voice::observedFrame<<','<<voice<<','<<stage<<','<<mask<<','<<candidate;
    for(unsigned i=0;i<22;++i) *output<<','<<((mask>>i)&1 ? after[i] : 0);
    *output<<'\n';
}
}
