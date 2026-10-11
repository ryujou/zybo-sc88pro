// SPDX-License-Identifier: GPL-3.0-only
#include "xp3_voice.h"
#include "xp3_core.h"
#include "xp3_common.h"

void xp3_voice_step(uint32_t state[xp3StateWords],uint32_t context[xp3ContextWords],
                    uint32_t command,uint32_t audio[4],
                    hls::stream<uint32_t>& requests,hls::stream<uint8_t>& replies)
{
#pragma HLS INTERFACE ap_memory port=state depth=102
#pragma HLS INTERFACE ap_memory port=context depth=40
#pragma HLS INTERFACE ap_memory port=audio depth=4
#pragma HLS INTERFACE ap_none port=command
#pragma HLS INTERFACE axis port=requests depth=32
#pragma HLS INTERFACE axis port=replies depth=32
#pragma HLS INTERFACE ap_ctrl_hs port=return
    xp3::XP xp;
#pragma HLS DISAGGREGATE variable=xp
#pragma HLS ARRAY_PARTITION variable=xp.m_state.voices complete dim=0
#pragma HLS ARRAY_PARTITION variable=xp.m_state.waveRomConfig complete dim=0
#pragma HLS ARRAY_PARTITION variable=xp.m_waveRoms complete dim=0
    xp3::unpackVoice(xp.m_state.voices[0],state);
    xp3::unpackVoice(xp.m_state.voices[1],state+xp3VoiceWords);
    auto& s=xp.m_state;
    s.sampleClock=uint64_t(context[0])|(uint64_t(context[1])<<32);
    s.irqStatus=context[2]&65535; s.irqConfigMask=context[3]&65535;
    s.interrupt=context[4]&1; xp.m_irqEventAcceptedThisStep=context[5]&1; s.irqBlockedEvent=context[6]&1;
    for (unsigned cs=0; cs<8; ++cs) {
        s.waveRomConfig[cs]=context[7+cs]&255;
        xp.m_waveRoms[cs].size=context[15+cs]&0x1ffffff;
        xp.m_waveRoms[cs].width=(context[23+cs]&1) ? xp3::XP::PhysicalWaveRomWidth::bits16 : xp3::XP::PhysicalWaveRomWidth::bits8;
        xp.m_waveRoms[cs].voiceBankShift=(context[23+cs]>>8)&15;
    }
    const unsigned operation=command&3,slot=(command>>16)&1;
    auto& voice=s.voices[slot];
    const int32_t prior=xp3::xpInternal::signExtend(voice.filterOutput_2a00,24);
    if (operation==2) {
        xp.stepPairedVoiceFilter(s.voices[0],s.voices[1],static_cast<int32_t>(audio[0]),static_cast<int32_t>(audio[1]));
        audio[0]=s.voices[0].filterOutput_2a00; audio[1]=0;
    } else {
        xp3::XP::VoiceStepResult sample{};
        if (!voice.resetState_3900.released) {
            if (voice.tvaGain_2700) voice.tvaGain_2700=static_cast<uint16_t>(std::max<uint32_t>(1,(voice.tvaGain_2700*7u)>>3));
            voice.filterBp_2800=voice.filterLp_2900=voice.filterOutput_2a00=0;
        } else {
            const auto phase=voice.runtimeCache.runtimePhase;
            if (phase==xp3::XP::VoiceRuntimePhaseCache::starting || phase==xp3::XP::VoiceRuntimePhaseCache::running) xp.stepTvaGain(voice);
            sample=xp.stepVoiceSource((command>>8)&63,voice,requests,replies);
            if (sample.filterDue && operation==0)
                voice.filterOutput_2a00=static_cast<uint32_t>(xp.applyTva(voice,xp.stepVoiceFilter(voice,sample.sample,(voice.filterConfig_2000>>10)&3)))&0xffffff;
        }
        audio[0]=static_cast<uint32_t>(sample.sample); audio[1]=sample.filterDue;
    }
    audio[2]=static_cast<uint32_t>(prior); audio[3]=voice.filterOutput_2a00;
    xp3::packVoice(s.voices[0],state); xp3::packVoice(s.voices[1],state+xp3VoiceWords);
    context[2]=s.irqStatus; context[3]=s.irqConfigMask; context[4]=s.interrupt;
    context[5]=xp.m_irqEventAcceptedThisStep; context[6]=s.irqBlockedEvent;
}
