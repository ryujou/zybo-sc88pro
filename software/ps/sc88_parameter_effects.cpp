// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_parameter_effects.h"
#include "custom_chips/xp/xp_dsp_ops.h"
extern "C" {
#include "sc88_parameter_audio.h"
}

extern "C" int sc88_parameter_effects(const sc88_prepared_frame* frame, const uint64_t* results,
                                      unsigned result_words, uint64_t* stereo)
{
    static Sc88ParameterEffects effects;
    if (result_words != frame->result_words || result_words < 68 || result_words > 320) return -1;
    for (unsigned i = 0; i < frame->control_count; ++i) effects.control(frame->controls[i]);
    return effects.process(results, result_words - 64, *stereo);
}

void Sc88ParameterEffects::control(uint64_t word)
{
    const unsigned kind = word & 255, target = (word >> 8) & 255;
    const uint16_t address = static_cast<uint16_t>(word >> 16);
    const uint8_t value = static_cast<uint8_t>(word >> 32);
    switch (kind) {
    case 1: host.reset(); lsp.clear(); gate = false; break;
    case 2:
        if (target == 1) host.hostWrite8(address, value);
        else lsp.hostWrite(address, value);
        break;
    case 3:
        if (target == 1) host.hostRead8(address);
        else if (target == 2) lsp.hostRead(address);
        break;
    case 4: gate = (value & 128) != 0; break;
    }
}

int Sc88ParameterEffects::process(const uint64_t* sends, unsigned count, uint64_t& stereo)
{
    auto& state = host.state();
    auto& dsp = state.dsp;
    const unsigned voices = (state.highestVoice & 63) + 1;
    if (count != voices * 4) return -1;
    xpLib::DspMixerFrame mixer;
    xpLib::DspMixerSummary summary{};
    for (unsigned slot = 0; slot < count; ++slot) {
        const uint64_t word = sends[slot];
        const unsigned cycle = slot + (slot % 4 == 1 ? 1 : 0);
        const uint64_t position = (uint64_t(cycle) << 54) | (uint64_t(slot / 4) << 48) |
                                  (uint64_t(slot % 4) << 46);
        if ((word & ~((UINT64_C(63) << 40) | UINT64_C(0x1ffffff))) != position) return -1;
        const uint32_t bits = static_cast<uint32_t>(word) & 0x1ffffff;
        const int64_t contribution = int64_t(bits & 0xffffff) - int64_t(bits & 0x1000000);
        mixer[slot / 4][slot % 4] = {size_t((word >> 40) & 63), contribution};
        summary.add(size_t((word >> 40) & 63), contribution);
    }
    dsp.beginMixerFrame();
    if ((state.dspControl & 4) && (state.sampleClock & 1))
        dsp.stepIram3Ramps(state.iram3RampRates, xpLib::Dsp::iram3PartitionCount(state.serialAudioConfig[1]),
                          static_cast<uint8_t>(state.sampleClock >> 1));
    xpLib::Dsp::StepRequest request{(state.dspControl & 4) != 0, (state.dspControl & 2) != 0,
        state.serialAudioConfig[0], state.serialAudioConfig[1], (state.dspControl & 3) == 3, count, &mixer};
    if (request.executeProgram) {
        dsp.hoistDeposits(request, summary);
        dsp.step(request);
    } else {
        // Stopped programs only deposit mixer sends and advance bank parity.
        // Do not lower a program that the host is still uploading.
        xpLib::DspFrameContext context;
        xpLib::dspOps::beginFrame(dsp.state(), context, request);
        for (unsigned cycle = 0; cycle < count; ++cycle)
            xpLib::dspOps::stepMixerCycle(dsp.state(), mixer, cycle);
        xpLib::dspOps::endFrame(dsp.state(), context);
    }
    ++state.sampleClock;
    using Bus = xpLib::Dsp::SerialBus;
    const auto& output = dsp.serialOutput(Bus::c);
    stereo = dsp.serialOutputCount(Bus::c) >= 2
        ? uint32_t(output[0]) | (uint64_t(uint32_t(output[1])) << 32) : 0;
    const auto& send = dsp.serialOutput(Bus::b);
    const auto n = dsp.serialOutputCount(Bus::b);
    const auto result = lsp.process({n > 0 ? send[0] : 0, n > 1 ? send[1] : 0});
    const int32_t returns[2] = {gate ? result.first >> 8 : 0, gate ? result.second >> 8 : 0};
    dsp.setSerialInput(Bus::a, returns, 2);
    return 0;
}
