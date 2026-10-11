// SPDX-License-Identifier: GPL-3.0-only
#include "voice_probe.h"
#include "custom_chips/xp/xp_voice_common.h"
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace fs=std::filesystem;
using XP=xpLib::XP;
constexpr uint32_t framesPerCase=256;

XP::VoiceState voiceSeed(unsigned format=0)
{
    XP::VoiceState v{};
    v.waveControl_0000=format==2 ? XP::WaveControl::ldpcmFormat : format==1 ? XP::WaveControl::fceDpcmExponent0OrProducerLive : 0;
    v.sampleCurrent_0100=0x40030; v.sampleLoop_0200=0x40040; v.sampleEnd_0300=0x4007f;
    v.pitchCurrent_1b00=v.pitchDestination_1200=0x38000;
    v.tvfFCurrent_1c00=v.tvfFDestination_1300=0x30000;
    v.ampCurrent_1e00=v.ampDestination_1500=0x18000;
    v.ampModCurrent_1d00=v.ampModDestination_1400=0x1fffe;
    v.tvfQCurrent_2100=0x20000; v.tvfQDestination_1100=0x8000;
    v.pitchRamp_1700=v.tvfFRamp_1800=v.tvfQRamp_1600=v.ampModRamp_1900=v.ampRamp_1a00=0x20000;
    v.tvaGain_2700=0x6000; v.combinedAmp_2300=xpLib::xpInternal::combineAmp(v);
    v.resetState_3900={true,true}; v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::preload;
    return v;
}

void runningSeed(XP::VoiceState& v, unsigned format=0)
{
    v.runtimeCache.runtimePhase=XP::VoiceRuntimePhaseCache::running;
    v.runtimeCache.waveSampleFormat=static_cast<XP::WaveSampleFormatCache>(format);
    v.playbackStateConfig_1000=0x30000;
    v.pitchIncrement_0d00=xpLib::xpInternal::decodePitch(v.pitchCurrent_1b00);
    v.tvfFCoefficient_2200=(xpLib::xpInternal::decodePitch(v.tvfFCurrent_1c00)<<2)&0xfffff;
    v.waveFetchState_0400=0x87765;
    for (size_t i=0; i<8; ++i) v.waveCircularBuffer_0800[i]=static_cast<uint16_t>((i*31+17)&255) | (format==0 ? 0x300 : 0);
}

void setup(XP& xp, const std::string& name, const std::vector<uint8_t>& rom)
{
    xp.reset();
    xp.mapWaveRom(0,rom.data(),rom.size(),name=="physical_bus8" ? XP::PhysicalWaveRomWidth::bits8 : XP::PhysicalWaveRomWidth::bits16);
    auto& s=xp.state(); s.highestVoice=0; s.waveRomConfig[0]=name=="fetch_bus8" || name=="physical_bus8" ? 0 : 1;
    const unsigned format=name=="exponent_zero" ? 1 : name=="ldpcm" ? 2 : 0;
    s.voices[0]=voiceSeed(format);
    auto& v=s.voices[0];
    if (name=="silence") v=XP::VoiceState{};
    if (name.starts_with("endpoint_exponent")) {v.sampleCurrent_0100=v.sampleLoop_0200=v.sampleEnd_0300=0;v.pitchCurrent_1b00=v.pitchDestination_1200=0x3ffff;}
    if (name.starts_with("endpoint_exponent_q")) {v.tvfQRamp_1600=0x3ff;v.tvfQDestination_1100=0x3fffe;}
    if (name.starts_with("endpoint_exponent_f")) {v.tvfFRamp_1800=0x3ff;v.tvfFDestination_1300=0x3fffe;}
    if (name.starts_with("endpoint_exponent") && name.find("_pair_")!=std::string::npos) {s.highestVoice=1;s.voices[1]=v;v.filterConfig_2000=((std::stoul(name.substr(name.rfind('_')+1))-1)<<12)|XP::FilterConfig::pairRole|(1<<10)|(2<<8)|(3<<6);}
    if (name=="zero_pitch") v.pitchCurrent_1b00=v.pitchDestination_1200=0;
    if (name=="preload_odd") ++v.sampleCurrent_0100;
    if (name=="consumer_limited") v.addressFraction_0e00=10;
    if (name=="unmapped_cs") v.waveControl_0000|=0x70;
    if (name=="fractional_pitch") v.pitchCurrent_1b00=v.pitchDestination_1200=0x36043;
    if (name=="maximum_pitch") v.pitchCurrent_1b00=v.pitchDestination_1200=0x3ffff;
    if (name=="reverse_loop") { v.waveControl_0000|=XP::WaveControl::reverse; v.sampleCurrent_0100=0x4007f; v.sampleLoop_0200=0x40070; v.sampleEnd_0300=0x40030; }
    if (name=="alternate_loop") v.waveControl_0000|=XP::WaveControl::alternateLoop;
    if (name=="endpoint_hold") v.sampleLoop_0200=v.sampleEnd_0300=0x40038;
    if (name=="address_wrap") { v.sampleCurrent_0100=0xffffc; v.sampleLoop_0200=0x40000; v.sampleEnd_0300=0x80000; }
    if (name=="consumer_blocked") v.addressFraction_0e00=3;
    if (name=="wave_halt") v.waveControl_0000|=XP::WaveControl::waveEngineHalt;
    if (name=="pitch_linear" || name=="pitch_log") { v.pitchRamp_1700=(name=="pitch_linear" ? 0x04000 : 0)|0x3ff; v.pitchDestination_1200=0x3a000; }
    if (name=="tvf_linear" || name=="tvf_log") { v.tvfFRamp_1800=(name=="tvf_linear" ? 0x04000 : 0)|0x3ff; v.tvfFDestination_1300=0x34000; }
    if (name=="amp_mod_ramp") { v.ampModRamp_1900=0x3ff; v.ampModDestination_1400=0x4000; }
    if (name=="q_ramp") { v.tvfQRamp_1600=0x3ff; v.tvfQDestination_1100=0x3fffe; }
    if (name=="amp_mod_sum") v.ampModRamp_1900|=0x4000;
    if (name=="amp_hold_pending") { v.ampRamp_1a00=0x243ff; v.ampDestination_1500=0; }
    if (name.starts_with("amp_curve_")) { const auto curve=std::stoul(name.substr(10)); v.ampRamp_1a00=(curve<<14)|0x3ff; v.ampDestination_1500=0; v.ampStep_2600=0xfffff; v.runtimeCache.ampCurve2EntryPending=curve==2; }
    if (name.starts_with("ramp_divider_")) { const auto divider=std::stoul(name.substr(13)); v.ampRamp_1a00=(divider<<12)|0x3ff; v.ampDestination_1500=0; if (divider==3) s.sampleClock=252; }
    if (name.starts_with("filter_mode_")) v.filterConfig_2000=std::stoul(name.substr(12))<<10;
    if (name=="filter_extreme" || name=="tva_saturation")
    {
        runningSeed(v); v.filterLp_2900=0x7fffff; v.filterBp_2800=0x800000;
        v.tvfFCoefficient_2200=v.tvfQCurrent_2100=0xfffff;
        if (name=="tva_saturation") { v.tvaGain_2700=0xffff; v.combinedAmp_2300=0xffffe; }
    }
    if (name=="tva_reset_decay") { v.resetState_3900={false,false}; v.tvaGain_2700=65535; }
    if (name=="tva_zero") { v.tvaGain_2700=v.ampCurrent_1e00=v.ampDestination_1500=v.combinedAmp_2300=0; }
    if (name=="filter_negative_truncation") { runningSeed(v); v.filterLp_2900=0; v.filterBp_2800=0xffffff; v.tvfFCoefficient_2200=v.tvfQCurrent_2100=1; }
    if (name=="accumulator_wrap") { runningSeed(v,1); v.dpcmAccumulator_0c00=0x3fffc; for (auto& cell:v.waveCircularBuffer_0800) cell=127; }
    if (name=="phase_wrap") { runningSeed(v); v.addressFraction_0e00=xpLib::xpInternal::packAddressPhase(0x3ffff); }
    if (name=="phase_sweep") { runningSeed(v); v.pitchIncrement_0d00=v.pitchCurrent_1b00=v.pitchDestination_1200=0; }
    if (name=="irq_retry") { s.irqConfigMask=0x1ff; s.interrupt=true; s.irqStatus=0x1234; v.waveControl_0000|=XP::WaveControl::irqEnable|XP::WaveControl::muteRequest; }
    if (name=="loop_irq") { s.irqConfigMask=1<<5; v.waveControl_0000|=XP::WaveControl::irqEnable; }
    if (name=="ramp_irq") { s.irqConfigMask=1<<4; v.ampRamp_1a00=0x103ff; v.ampDestination_1500=0; }
    if (name.starts_with("pair_structure_"))
    {
        const auto structure=std::stoul(name.substr(15));
        s.highestVoice=1; s.voices[1]=voiceSeed(2);
        s.voices[1].sampleCurrent_0100+=7; s.voices[1].tvaGain_2700=0x7fff;
        v.filterConfig_2000=((structure-1)<<12)|XP::FilterConfig::pairRole|(1<<10)|(2<<8)|(3<<6);
    }
}

void event(XP& xp, std::ofstream& out, uint64_t frame, const std::string& name)
{
    auto& v=xp.state().voices[0];
    if (name=="phase_sweep")
    {
        v.addressFraction_0e00=xpLib::xpInternal::packAddressPhase((frame%128)<<7);
        out << frame << ",voice[0].addressFraction_0e00," << v.addressFraction_0e00 << '\n';
    }
    if (name=="irq_retry" && frame==32)
    {
        xp.hostRead(XP::HostAddress::irqAcknowledge_391a);
        out << frame << ",hostRead,14618\n";
    }
    if (name=="amp_hold_pending" && frame==64)
    {
        v.ampRamp_1a00=0x043ff;
        out << frame << ",voice[0].ampRamp_1a00,17407\n";
    }
    if (name=="retrigger" && (frame==64 || frame==128))
    {
        xp.hostWrite(XP::HostAddress::voiceReset_3900,frame==64 ? 0 : 1);
        out << frame << ",releaseMask," << (frame==64 ? 0 : 1) << '\n';
        if (frame==128) { xp.hostRead(XP::HostAddress::voiceReset_3900); out << frame << ",commitRelease,0\n"; }
    }
    if (name=="power_reset" && (frame==64 || frame==128))
    {
        xp.reset(); xp.state().highestVoice=0;
        out << frame << ",powerReset,0\n";
    }
}

int main(int argc, char** argv)
{
    try
    {
        if (argc!=2 && (argc!=3 || std::string(argv[2])!="--pressure")) throw std::runtime_error("Usage: sc88_voice_vectors OUTPUT_DIR [--pressure]");
        const fs::path out(argv[1]); fs::create_directories(out);
        std::vector<uint8_t> rom(1<<20);
        for (size_t i=0; i<rom.size(); ++i) rom[i]=static_cast<uint8_t>(i*73+(i>>8)+19);
        for (size_t i=0; i<0x8000; ++i) rom[i]=static_cast<uint8_t>((i%11)|(((i+3)%11)<<4));
        std::ofstream bytes(out/"synthetic-wave.bin",std::ios::binary); bytes.exceptions(std::ios::badbit|std::ios::failbit);
        bytes.write(reinterpret_cast<const char*>(rom.data()),rom.size()); bytes.close();
        std::vector<std::string> names={"silence","fce_dpcm","fetch_bus8","physical_bus8","exponent_zero","ldpcm","reserved_exponent","zero_pitch","fractional_pitch","maximum_pitch","reverse_loop","alternate_loop","endpoint_hold","address_wrap","consumer_blocked","wave_halt","pitch_linear","pitch_log","tvf_linear","tvf_log","amp_mod_ramp","q_ramp","amp_mod_sum","amp_curve_0","amp_curve_1","amp_curve_2","amp_curve_3","ramp_divider_1","ramp_divider_2","ramp_divider_3","filter_mode_0","filter_mode_1","filter_mode_2","filter_mode_3","filter_extreme","tva_saturation","tva_reset_decay","accumulator_wrap","phase_wrap","phase_sweep","irq_retry","retrigger","power_reset","pair_structure_2","pair_structure_3","pair_structure_4","pair_structure_5","pair_structure_6","pair_structure_7","pair_structure_8","pair_structure_9","pair_structure_10","preload_odd","consumer_limited","unmapped_cs","amp_hold_pending","tva_zero","filter_negative_truncation","loop_irq","ramp_irq"};
        if(argc==3)
        {
            names={"endpoint_exponent_refresh","endpoint_exponent_q","endpoint_exponent_f"};
            for(const auto& kind:{"refresh","q","f"}) for(unsigned structure=2;structure<=10;++structure)
                names.push_back(std::string("endpoint_exponent_")+kind+"_pair_"+std::to_string(structure));
        }
        std::ofstream manifest(out/"manifest.csv"); manifest.exceptions(std::ios::badbit|std::ios::failbit);
        manifest << "case,frames,rom_reads,active_frames\n";
        for (const auto& name:names)
        {
            const auto path=out/name; fs::create_directories(path);
            auto xp=std::make_unique<XP>(); setup(*xp,name,rom);
            if (name=="reserved_exponent")
            {
                runningSeed(xp->state().voices[0]);
                xp->state().voices[0].pitchCurrent_1b00=xp->state().voices[0].pitchDestination_1200=xp->state().voices[0].pitchIncrement_0d00=0;
                for (auto& cell:xp->state().voices[0].waveCircularBuffer_0800) cell=0x0f7f;
            }
            std::ofstream initial(path/"initial.csv"), expected(path/"expected.csv"), reads(path/"rom-reads.csv"), stages(path/"stages.csv"), events(path/"events.csv");
            std::ofstream sourceBefore(path/"source-before.csv"), sourceAfter(path/"source-after.csv");
            sc88voice::sourceHeader(sourceBefore,xp->state()); sc88voice::sourceHeader(sourceAfter,xp->state());
            initial.exceptions(std::ios::badbit|std::ios::failbit); expected.exceptions(std::ios::badbit|std::ios::failbit); events.exceptions(std::ios::badbit|std::ios::failbit);
            sc88voice::csvHeader(initial,xp->state()); sc88voice::csvRow(initial,xp->state(),0);
            sc88voice::csvHeader(expected,xp->state()); sc88voice::romHeader(reads); sc88voice::stageHeader(stages);
            events << "frame,event,value\n";
            sc88voice::romReads=&reads; sc88voice::stages=&stages; sc88voice::romReadCount=0;
            sc88voice::sourceBefore=&sourceBefore; sc88voice::sourceAfter=&sourceAfter;
            uint64_t active=0;
            for (uint64_t frame=0; frame<framesPerCase; ++frame)
            {
                event(*xp,events,frame,name);
                sc88voice::observedFrame=frame; sc88voice::observedVoices=xp->state().voices.data();
                xp->step(); sc88voice::csvRow(expected,xp->state(),frame);
                if (xp->state().voices[0].filterOutput_2a00) ++active;
            }
            sc88voice::romReads=nullptr; sc88voice::stages=nullptr;
            sc88voice::sourceBefore=nullptr; sc88voice::sourceAfter=nullptr;
            manifest << name << ',' << framesPerCase << ',' << sc88voice::romReadCount << ',' << active << '\n';
            std::cout << "  " << name << ": frames=" << framesPerCase << " ROM reads=" << sc88voice::romReadCount << " active=" << active << '\n';
        }
        std::ofstream pitch(out/"pitch-table.csv"); pitch.exceptions(std::ios::badbit|std::ios::failbit);
        pitch << "index,mantissa\n";
        for (size_t i=0; i<256; ++i) pitch << i << ',' << xpLib::xpInternal::pitchMantissa[i] << '\n';
        std::ofstream interpolation(out/"interpolation-table.csv"); interpolation.exceptions(std::ios::badbit|std::ios::failbit);
        interpolation << "tap,phase,coefficient\n";
        for (size_t tap=0; tap<3; ++tap) for (size_t phase=0; phase<128; ++phase)
            interpolation << tap << ',' << phase << ',' << xpLib::xpInternal::interpolationCoefficients[tap][phase] << '\n';
        std::cout << "SC88_VOICE_VECTORS_COMPLETE cases=" << names.size() << '\n';
        return 0;
    }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
