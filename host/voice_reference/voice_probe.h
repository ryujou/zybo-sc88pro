// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "custom_chips/xp/xp.h"
#include "custom_chips/xp/xp_dsp_ops.h"
#include <fstream>
#include <string>
#include <map>
#include <stdexcept>

namespace sc88voice
{
using XP = xpLib::XP;

// Keep the host-visible storage names, including the launch caches needed between frames.
#define SC88_VOICE_FIELDS(F) \
    F(waveControl_0000) F(sampleCurrent_0100) F(sampleLoop_0200) F(sampleEnd_0300) F(waveFetchState_0400) \
    F(dpcmAccumulator_0c00) F(pitchIncrement_0d00) F(addressFraction_0e00) F(playbackStateConfig_1000) \
    F(tvfQDestination_1100) F(pitchDestination_1200) F(tvfFDestination_1300) F(ampModDestination_1400) F(ampDestination_1500) \
    F(tvfQRamp_1600) F(pitchRamp_1700) F(tvfFRamp_1800) F(ampModRamp_1900) F(ampRamp_1a00) \
    F(pitchCurrent_1b00) F(tvfFCurrent_1c00) F(ampModCurrent_1d00) F(ampCurrent_1e00) \
    F(filterConfig_2000) F(tvfQCurrent_2100) F(tvfFCoefficient_2200) F(combinedAmp_2300) \
    F(pitchStep_2400) F(tvfFStep_2500) F(ampStep_2600) F(tvaGain_2700) \
    F(filterBp_2800) F(filterLp_2900) F(filterOutput_2a00) \
    F(resetState_3900.released) F(resetState_3900.shadow) \
    F(runtimeCache.ampCurve2EntryPending) F(runtimeCache.runtimePhase) F(runtimeCache.waveSampleFormat)

template<class F> void fields(const XP::State& s, uint64_t frame, F emit, size_t firstVoice=0, size_t voiceCount=2)
{
    emit("frame", frame); emit("sampleClock", s.sampleClock);
    emit("irqStatus", s.irqStatus); emit("irqConfigMask", s.irqConfigMask);
    emit("interrupt", s.interrupt); emit("irqBlockedEvent", s.irqBlockedEvent);
    for (size_t i=0; i<s.waveRomConfig.size(); ++i)
        emit("waveRomConfig["+std::to_string(i)+"]", s.waveRomConfig[i]);
    for (size_t i=firstVoice; i<firstVoice+voiceCount; ++i)
    {
        const auto& v=s.voices[i];
        const std::string prefix="voice["+std::to_string(i)+"].";
#define FIELD(member) emit(prefix+#member, static_cast<uint64_t>(v.member));
        SC88_VOICE_FIELDS(FIELD)
#undef FIELD
        for (size_t n=0; n<v.waveCircularBuffer_0800.size(); ++n)
            emit(prefix+"waveCircularBuffer_0800["+std::to_string(n)+"]", v.waveCircularBuffer_0800[n]);
        for (size_t n=0; n<v.mixer_3a00.size(); ++n)
            emit(prefix+"mixer_3a00["+std::to_string(n)+"]", v.mixer_3a00[n]);
    }
}

inline void csvHeader(std::ostream& out, const XP::State& state, size_t firstVoice=0, size_t voiceCount=2)
{
    bool first=true;
    fields(state, 0, [&](const std::string& name, uint64_t) { if (!first) out << ','; first=false; out << name; },firstVoice,voiceCount);
    out << '\n';
}
inline void csvRow(std::ostream& out, const XP::State& state, uint64_t frame, size_t firstVoice=0, size_t voiceCount=2)
{
    bool first=true;
    fields(state, frame, [&](const std::string&, uint64_t value) { if (!first) out << ','; first=false; out << value; },firstVoice,voiceCount);
    out << '\n';
}

inline std::map<std::string,uint64_t> precedingPostState;
inline void recordControlInputs(std::ostream& out,const XP::State& state,uint64_t frame,size_t firstVoice)
{
    if (precedingPostState.empty()) return;
    fields(state,frame,[&](const std::string& name,uint64_t value) {
        if (name=="frame" || name=="irqBlockedEvent") return;
        if (name=="sampleClock") {
            if (value!=precedingPostState.at(name)) throw std::runtime_error("Unexpected inter-frame clock change");
            return;
        }
        if (value!=precedingPostState.at(name)) out<<frame<<','<<name<<','<<value<<'\n';
    },firstVoice);
}
inline void rememberPostState(const XP::State& state,uint64_t frame,size_t firstVoice)
{
    fields(state,frame,[&](const std::string& name,uint64_t value) { precedingPostState[name]=value; },firstVoice);
}

inline std::ofstream* romReads=nullptr;
inline std::ofstream* stages=nullptr;
inline std::ofstream* sourceBefore=nullptr;
inline std::ofstream* sourceAfter=nullptr;
inline const XP::VoiceState* observedVoices=nullptr;
inline size_t observedVoiceCount=2;
inline uint64_t observedFrame=0, romReadCount=0;
inline std::ofstream* mixerSends=nullptr;
inline std::ofstream* mixerCells=nullptr;
inline xpLib::DspState diagnosticMixer{};
inline void recordMixer(const xpLib::DspMixerFrame& frame, size_t voiceCount)
{
    if (mixerCells)
    {
        diagnosticMixer.iramSelPhase=observedFrame&1;
        xpLib::dspOps::beginMixerFrame(diagnosticMixer);
        for(size_t cycle=0;cycle<voiceCount*4;++cycle) xpLib::dspOps::stepMixerCycle(diagnosticMixer,frame,cycle);
        *mixerCells<<observedFrame<<','<<(observedFrame&1)<<','<<diagnosticMixer.mixerInitialized;
        for(auto value:xpLib::dspOps::mixerIram(diagnosticMixer)) *mixerCells<<','<<xpLib::dspOps::signExtend(value,24);
        *mixerCells<<'\n';
    }
    if (!mixerSends) return;
    constexpr unsigned cycles[4]={0,2,2,3};
    for(size_t voice=0;voice<voiceCount;++voice) for(size_t send=0;send<4;++send)
        *mixerSends<<observedFrame<<','<<voice<<','<<send<<','<<voice*4+cycles[send]<<','
                   <<frame[voice][send].destination<<','<<frame[voice][send].contribution<<'\n';
}
template<class F> void sourceFields(const XP::State& state,size_t index,bool accepted,bool physical16,unsigned bankShift,F emit)
{
    const auto& v=state.voices[index];
    emit("frame",observedFrame); emit("voice",observedVoiceCount>2 ? index : &v==observedVoices ? 0 : 1); emit("voiceIndex",index);
    emit("sampleClock",state.sampleClock); emit("irqStatus",state.irqStatus); emit("irqConfigMask",state.irqConfigMask);
    emit("interrupt",state.interrupt); emit("acceptedThisFrame",accepted); emit("irqBlockedEvent",state.irqBlockedEvent);
    emit("descriptor",state.waveRomConfig[(v.waveControl_0000>>4)&7]); emit("physical16",physical16); emit("bankShift",bankShift);
#define SOURCE_FIELD(member) emit(#member,static_cast<uint64_t>(v.member));
    SOURCE_FIELD(waveControl_0000) SOURCE_FIELD(sampleCurrent_0100) SOURCE_FIELD(sampleLoop_0200) SOURCE_FIELD(sampleEnd_0300)
    SOURCE_FIELD(waveFetchState_0400) SOURCE_FIELD(dpcmAccumulator_0c00) SOURCE_FIELD(pitchIncrement_0d00)
    SOURCE_FIELD(addressFraction_0e00) SOURCE_FIELD(playbackStateConfig_1000)
    SOURCE_FIELD(runtimeCache.runtimePhase) SOURCE_FIELD(runtimeCache.waveSampleFormat)
#undef SOURCE_FIELD
    for(size_t cell=0;cell<8;++cell) emit("waveCircularBuffer_0800["+std::to_string(cell)+"]",v.waveCircularBuffer_0800[cell]);
}
inline void sourceHeader(std::ofstream& out,const XP::State& state,size_t index=0)
{
    out.exceptions(std::ios::badbit|std::ios::failbit);
    bool first=true;
    sourceFields(state,index,false,false,0,[&](const std::string& name,uint64_t) { if(!first) out<<','; first=false; out<<name; });
    out<<'\n';
}
inline void recordSource(bool after,const XP::State& state,size_t index,bool accepted,bool physical16,unsigned bankShift)
{
    auto* out=after ? sourceAfter : sourceBefore;
    const auto* voice=&state.voices[index];
    if(!out || voice<observedVoices || voice>=observedVoices+observedVoiceCount) return;
    bool first=true;
    sourceFields(state,index,accepted,physical16,bankShift,[&](const std::string&,uint64_t value) { if(!first) *out<<','; first=false; *out<<value; });
    *out<<'\n';
}
inline void recordRomRead(const XP::VoiceState* voice, size_t cs, size_t bank,
                          size_t logical, size_t physical, uint8_t value)
{
    if (!romReads || voice<observedVoices || voice>=observedVoices+observedVoiceCount) return;
    const auto slot=voice-observedVoices;
    *romReads << observedFrame << ',' << slot << ',' << cs << ',' << bank << ','
              << logical << ',' << physical << ',' << unsigned(value) << '\n';
    ++romReadCount;
}
inline void romHeader(std::ofstream& out)
{
    out.exceptions(std::ios::badbit|std::ios::failbit);
    out << "frame,voice,chip_select,bank,logical_address,physical_address,value\n";
}
inline void recordStage(const XP::VoiceState* voice, const char* stage,
                        int64_t a, int64_t b=0, int64_t c=0, int64_t d=0,
                        int64_t e=0, int64_t f=0, int64_t g=0, int64_t h=0)
{
    if (!stages || voice<observedVoices || voice>=observedVoices+observedVoiceCount) return;
    *stages << observedFrame << ',' << (voice-observedVoices) << ',' << stage
            << ',' << a << ',' << b << ',' << c << ',' << d << ',' << e << ',' << f << ',' << g << ',' << h << '\n';
}
inline void stageHeader(std::ofstream& out)
{
    out.exceptions(std::ios::badbit|std::ios::failbit);
    out << "frame,voice,stage,a,b,c,d,e,f,g,h\n";
}
}
