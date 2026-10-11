// SPDX-License-Identifier: GPL-3.0-only
#include "trace.h"
#include <cstring>
#include <stdexcept>

namespace sc88trace
{
Writer* active = nullptr;
uint32_t crc32(const void* bytes, size_t size, uint32_t prior)
{
    static const auto table = [] {
        std::array<uint32_t, 256> result{};
        for (uint32_t i=0; i<256; ++i)
        {
            uint32_t value=i;
            for (int bit=0; bit<8; ++bit) value=(value>>1)^((value&1) ? 0xedb88320u : 0);
            result[i]=value;
        }
        return result;
    }();
    uint32_t value=prior ^ 0xffffffffu;
    auto data=static_cast<const uint8_t*>(bytes);
    for (size_t i=0; i<size; ++i) value=table[(value^data[i])&255]^(value>>8);
    return value ^ 0xffffffffu;
}

Probe probe(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate, bool named)
{
    Probe p{{}, {}, named};
    p.words.reserve(135000);
    p.field("board.return_gate", gate);
    const auto& s=xp.state();
#define FIELD(obj, member) p.field(#obj "." #member, obj.member)
#define ARRAY(obj, member) p.array(#obj "." #member, obj.member)
    FIELD(s, readbackLatch); FIELD(s, wideWriteLatch); FIELD(s, highestVoice);
    FIELD(s, irqStatus); FIELD(s, irqConfigMask); FIELD(s, irqAcknowledge); FIELD(s, irqBlockedEvent);
    ARRAY(s, waveRomConfig); FIELD(s, waveRomPage); FIELD(s, waveRomBank); ARRAY(s, serialAudioConfig);
    FIELD(s, diagnosticSelect_3930); FIELD(s, serialFormat_3932); FIELD(s, voiceWindowSelect_3934);
    FIELD(s, dspControl); ARRAY(s, iram3RampRates); FIELD(s, sampleClock); FIELD(s, interrupt);
    for (size_t i=0; i<s.voices.size(); ++i)
    {
        const auto& v=s.voices[i];
        const std::string name=named ? "voice["+std::to_string(i)+"]." : "voice";
#define V(member) p.field(name + #member, v.member)
        V(waveControl_0000); V(sampleCurrent_0100); V(sampleLoop_0200); V(sampleEnd_0300); V(waveFetchState_0400);
        p.array(name+"waveCircularBuffer_0800", v.waveCircularBuffer_0800);
        V(dpcmAccumulator_0c00); V(pitchIncrement_0d00); V(addressFraction_0e00); V(playbackStateConfig_1000);
        V(tvfQDestination_1100); V(pitchDestination_1200); V(tvfFDestination_1300); V(ampModDestination_1400); V(ampDestination_1500);
        V(tvfQRamp_1600); V(pitchRamp_1700); V(tvfFRamp_1800); V(ampModRamp_1900); V(ampRamp_1a00);
        V(pitchCurrent_1b00); V(tvfFCurrent_1c00); V(ampModCurrent_1d00); V(ampCurrent_1e00);
        V(filterConfig_2000); V(tvfQCurrent_2100); V(tvfFCoefficient_2200); V(combinedAmp_2300);
        V(pitchStep_2400); V(tvfFStep_2500); V(ampStep_2600); V(tvaGain_2700);
        V(filterBp_2800); V(filterLp_2900); V(filterOutput_2a00);
        p.array(name+"mixer_3a00", v.mixer_3a00);
        V(resetState_3900.released); V(resetState_3900.shadow);
        V(runtimeCache.ampCurve2EntryPending); V(runtimeCache.runtimePhase); V(runtimeCache.waveSampleFormat);
#undef V
    }
    const auto& d=s.dsp.state();
    FIELD(d, accumulator); FIELD(d, iramReadLatch); FIELD(d, multiplyResultLatch); FIELD(d, multiplyFeedbackLatch);
    FIELD(d, eramReadLatch); FIELD(d, eramPendingWriteValue); FIELD(d, iram3ParameterLatch); FIELD(d, eramIndexedOffset);
    FIELD(d, eramPrefixPending); FIELD(d, eramPendingWrite); FIELD(d, eramOffsetHigh); FIELD(d, iramSelPhase); FIELD(d, multiplyNegativeFraction);
    for (size_t i=0; i<d.pendingEramReads.size(); ++i)
    {
        p.field("d.pendingEramReads["+std::to_string(i)+"].countdown", d.pendingEramReads[i].countdown);
        p.field("d.pendingEramReads["+std::to_string(i)+"].value", d.pendingEramReads[i].value);
    }
    FIELD(d, eramPos); FIELD(d, outputWordPosition); FIELD(d, dacPortPosition); FIELD(d, outputPins); FIELD(d, mixerInitialized);
    ARRAY(d, serialInputNode); ARRAY(d, serialInputCount); ARRAY(d, serialInputIndex); ARRAY(d, serialOutputCount);
    for (size_t i=0; i<d.serialInput.size(); ++i) p.array("d.serialInput["+std::to_string(i)+"]", d.serialInput[i]);
    for (size_t i=0; i<d.serialOutput.size(); ++i) p.array("d.serialOutput["+std::to_string(i)+"]", d.serialOutput[i]);
    ARRAY(d, iram1); ARRAY(d, iram2); ARRAY(d, iram3); ARRAY(d, eram);
    p.array("xp.pram", s.dsp.pram()); p.array("xp.cram", s.dsp.cram());
    const auto& r=lsp.runtime();
    FIELD(r, audioInL); FIELD(r, audioInR); FIELD(r, audioOutL); FIELD(r, audioOutR); ARRAY(r, accs);
    FIELD(r, eramReadValue); FIELD(r, eramWriteLatch); FIELD(r, eramSecondTapOffs); FIELD(r, multiplCoef1); FIELD(r, multiplCoef2);
    FIELD(r, audioOut); FIELD(r, audioIn); FIELD(r, jumpPending); FIELD(r, bufferPos); FIELD(r, eramPos);
    ARRAY(r, iram); ARRAY(r, eram);
    p.field("lsp.config", lsp.config()); p.field("lsp.running", lsp.running());
    const auto& program=lsp.program();
    ARRAY(program, words); ARRAY(program, coefs); ARRAY(program, eramAddr);
    FIELD(program, hasProgram); FIELD(program, hasJump); FIELD(program, hasBackwardJump); FIELD(program, taintBits);
#undef FIELD
#undef ARRAY
    return p;
}

Writer::Writer(const std::filesystem::path& path, uint64_t boot, uint64_t frames, const std::string& commit)
    : output(path, std::ios::binary)
{
    output.exceptions(std::ios::badbit | std::ios::failbit);
    if (commit.size()!=40) throw std::runtime_error("Invalid upstream identity");
    std::memcpy(header.magic, "SC88TRC1", 8);
    header.version=1; header.rate=32000; header.bootFrames=boot; header.caseFrames=frames;
    std::memcpy(header.commit, commit.data(), 40);
    header.interval=32768;
    header.crc=crc32(&header, 76);
    output.write(reinterpret_cast<const char*>(&header), sizeof(header));
}

void Writer::record(uint8_t kind, uint8_t chip, uint16_t address, uint32_t value, const Probe* state)
{
    if (!started || complete) return;
    Record r{frameIndex, sequence++, kind, chip, address, value, 0};
    if (state) r.value=static_cast<uint32_t>(state->words.size()*8);
    r.crc=crc32(&r, 20);
    if (state) r.crc=crc32(state->words.data(), r.value, r.crc);
    output.write(reinterpret_cast<const char*>(&r), sizeof(r));
    if (state) output.write(reinterpret_cast<const char*>(state->words.data()), r.value);
}
void Writer::reset(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (started) throw std::runtime_error("Unexpected second powerCycle in trace capture");
    started=true;
    record(Reset);
    auto state=probe(xp, lsp, gate);
    record(Checkpoint, 0, 0, 0, &state);
}
void Writer::frame(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (!started) return;
    record(Frame);
    ++frameIndex;
    sequence=0;
    if (frameIndex%header.interval==0)
    {
        auto state=probe(xp, lsp, gate);
        record(Checkpoint, 0, 0, 0, &state);
    }
}
void Writer::finish(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (!started || frameIndex!=header.bootFrames+header.caseFrames) throw std::runtime_error("Incomplete Trace frame capture");
    auto state=probe(xp, lsp, gate);
    record(End, 0, 0, 0, &state);
    complete=true;
    output.close();
}
void access(bool write, uint8_t chip, uint16_t address, uint8_t value) { if (active) active->record(write ? Write : Read, chip, address, value); }
void irqRead(bool pending) { if (active) active->record(Irq, 1, 0xfe8f, pending ? 0xfd : 0xff); }
void returnGate(uint8_t value) { if (active) active->record(Gate, 0, 0xfe86, value); }
void reset(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate) { if (active) active->reset(xp, lsp, gate); }
void frame(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate) { if (active) active->frame(xp, lsp, gate); }
}
