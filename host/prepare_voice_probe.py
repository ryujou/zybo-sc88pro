"""Generate observation-only XP ROM-read and replay Voice probes; keep pinned sources pristine."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/voice-overlay"


def replace_once(text, old, new):
    assert text.count(old) == 1, f"Pinned source observation boundary changed: {old}"
    return text.replace(old, new, 1)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "external/gearmulator/source/ronaldo/custom_chips/xp/xp_voice.cpp"
    voice = source.read_text(encoding="utf-8")
    voice = replace_once(voice, '#include "xp.h"', '#include "xp.h"\n#include "voice_probe.h"')
    probe_args = 'm_state, _voiceIndex, m_irqEventAcceptedThisStep, m_waveRoms[(_voice.waveControl_0000 >> 4) & 7].width == PhysicalWaveRomWidth::bits16, m_waveRoms[(_voice.waveControl_0000 >> 4) & 7].voiceBankShift'
    voice = replace_once(voice, 'raiseVoiceMuteEvent(_voiceIndex, _voice);',
                         f'sc88voice::recordSource(false, {probe_args});\n\t\tbool sourceRecorded = false;\n\t\tconst auto finishSource = [&] {{ if (!sourceRecorded) {{ sc88voice::recordSource(true, {probe_args}); sourceRecorded = true; }} }};\n\t\traiseVoiceMuteEvent(_voiceIndex, _voice);')
    source_step, remainder = voice.split('\n\tbool XP::voiceAddressRunsReverse', 1)
    assert source_step.count('stepVoiceRamps(_voiceIndex, _voice);') == 2
    source_step = source_step.replace('stepVoiceRamps(_voiceIndex, _voice);', 'finishSource();\n\t\tstepVoiceRamps(_voiceIndex, _voice);')
    source_step = source_step.replace('return {};', '{ finishSource(); return {}; }')
    source_step = source_step.replace('return {interpolatedSample, true};', 'finishSource();\n\t\treturn {interpolatedSample, true};')
    voice = source_step + '\n\tbool XP::voiceAddressRunsReverse' + remainder
    voice = replace_once(voice, "if (rom.data == nullptr || address >= rom.size)\n\t\t\treturn 0;", "if (rom.data == nullptr || address >= rom.size)\n\t\t{\n\t\t\tsc88voice::recordRomRead(&_voice, chipSelect, bank, voiceAddress, address, 0);\n\t\t\treturn 0;\n\t\t}")
    voice = replace_once(voice, "return rom.data[address];", "const auto value = rom.data[address];\n\t\tsc88voice::recordRomRead(&_voice, chipSelect, bank, voiceAddress, address, value);\n\t\treturn value;")
    voice = replace_once(voice, "const auto interpolatedSample = interpolateVoice(_voice, phase);", "const auto interpolatedSample = interpolateVoice(_voice, phase);\n\t\tsc88voice::recordStage(&_voice, \"interpolation\", phase, interpolatedSample);")
    (OUT / "xp_voice.cpp").write_text(voice, encoding="utf-8")
    xp = source.with_name("xp.cpp").read_text(encoding="utf-8")
    xp = replace_once(xp, '#include "xp.h"', '#include "xp.h"\n#include "voice_probe.h"')
    xp = replace_once(xp, 'prepareMixer(voiceCount);', 'prepareMixer(voiceCount);\n\t\tsc88voice::recordMixer(m_frame, voiceCount);')
    xp = replace_once(xp, "return selected;", 'sc88voice::recordStage(&_voice, "filter", _input, _mode, nextLp, highPass, nextBp, selected, frequency, damping);\n\t\treturn selected;')
    xp = replace_once(xp, "return saturateSigned24((static_cast<int64_t>(_input) * gain) / (int64_t{1} << 19));", 'const auto output = saturateSigned24((static_cast<int64_t>(_input) * gain) / (int64_t{1} << 19));\n\t\tsc88voice::recordStage(&_voice, "tva", _input, gain, output);\n\t\treturn output;')
    (OUT / "xp.cpp").write_text(xp, encoding="utf-8")
    replay = (ROOT / "host/trace/replay.cpp").read_text(encoding="utf-8")
    replay = replace_once(replay, '#include "trace.h"', '#include "trace.h"\n#include "voice_probe.h"')
    replay = replace_once(replay, 'if (argc!=5)', 'if (argc!=6)')
    replay = replace_once(replay, 'OUT_DIR UPSTREAM_COMMIT', 'OUT_DIR UPSTREAM_COMMIT FIRST_VOICE_OF_PAIR')
    replay = replace_once(replay, 'auto waves=loadWaves(argv[1]);', 'const size_t firstVoice=std::stoul(argv[5]);\n        if (firstVoice>62 || firstVoice%2) throw std::runtime_error("Probe requires an even Voice pair base in 0..62");\n        auto waves=loadWaves(argv[1]);')
    replay = replace_once(replay, 'fs::create_directories(out);', 'fs::create_directories(out);\n        std::ofstream waveImage(out/"decoded-wave.bin",std::ios::binary); waveImage.exceptions(std::ios::badbit|std::ios::failbit);\n        waveImage.write(reinterpret_cast<const char*>(waves.data()),waves.size()); waveImage.close();')
    replay = replace_once(replay, "uint64_t frameIndex=0,", "std::ofstream voiceStates(out/\"voice-expected.csv\"), voiceInitial(out/\"voice-initial.csv\"), romReads(out/\"voice-rom-reads.csv\");\n        voiceStates.exceptions(std::ios::badbit|std::ios::failbit);\n        voiceInitial.exceptions(std::ios::badbit|std::ios::failbit);\n        sc88voice::csvHeader(voiceStates,xp->state()); sc88voice::csvHeader(voiceInitial,xp->state());\n        sc88voice::romHeader(romReads);\n        uint64_t frameIndex=0,")
    replay = replace_once(replay, "xp->step();", "if (frameIndex==header.bootFrames) sc88voice::csvRow(voiceInitial,xp->state(),frameIndex);\n                sc88voice::observedFrame=frameIndex;\n                sc88voice::observedVoices=xp->state().voices.data();\n                sc88voice::romReads=frameIndex>=header.bootFrames ? &romReads : nullptr;\n                xp->step();\n                if (frameIndex>=header.bootFrames) sc88voice::csvRow(voiceStates,xp->state(),frameIndex);")
    replay = replace_once(replay, "boot.close(); pcm.close();", "boot.close(); pcm.close(); voiceStates.close(); voiceInitial.close(); romReads.close();\n        sc88voice::romReads=nullptr;\n        std::cout << \"SC88_VOICE_ROM_READS=\" << sc88voice::romReadCount << '\\n';")
    replay = replace_once(replay, "sc88voice::romHeader(romReads);", 'sc88voice::romHeader(romReads);\n        std::ofstream stages(out/"voice-stages.csv"); sc88voice::stageHeader(stages);')
    replay = replace_once(replay, "xp->step();", "sc88voice::stages=frameIndex>=header.bootFrames ? &stages : nullptr;\n                xp->step();")
    replay = replace_once(replay, "sc88voice::romReads=nullptr;", "sc88voice::romReads=nullptr; sc88voice::stages=nullptr; stages.close();")
    replay = replace_once(replay, 'sc88voice::csvHeader(voiceStates,xp->state()); sc88voice::csvHeader(voiceInitial,xp->state());', 'sc88voice::csvHeader(voiceStates,xp->state(),firstVoice); sc88voice::csvHeader(voiceInitial,xp->state(),firstVoice);')
    replay = replace_once(replay, 'sc88voice::csvRow(voiceInitial,xp->state(),frameIndex);', 'sc88voice::csvRow(voiceInitial,xp->state(),frameIndex,firstVoice);')
    replay = replace_once(replay, 'sc88voice::csvRow(voiceStates,xp->state(),frameIndex);', 'sc88voice::csvRow(voiceStates,xp->state(),frameIndex,firstVoice);')
    replay = replace_once(replay, 'sc88voice::observedVoices=xp->state().voices.data();', 'sc88voice::observedVoices=xp->state().voices.data()+firstVoice;')
    replay = replace_once(replay, 'uint64_t frameIndex=0,', 'std::ofstream controls(out/"voice-controls.csv"); controls.exceptions(std::ios::badbit|std::ios::failbit); controls<<"frame,event,value\\n";\n        uint64_t frameIndex=0,')
    replay = replace_once(replay, 'xp->step();', 'if (frameIndex>=header.bootFrames) sc88voice::recordControlInputs(controls,xp->state(),frameIndex,firstVoice);\n                xp->step();\n                if (frameIndex>=header.bootFrames) sc88voice::rememberPostState(xp->state(),frameIndex,firstVoice);')
    replay = replace_once(replay, 'stages.close();', 'stages.close(); controls.close();')
    replay = replace_once(replay, 'uint64_t frameIndex=0,', 'std::ofstream sourceBefore(out/"voice-source-before.csv"), sourceAfter(out/"voice-source-after.csv");\n        sc88voice::sourceHeader(sourceBefore,xp->state(),firstVoice); sc88voice::sourceHeader(sourceAfter,xp->state(),firstVoice);\n        uint64_t frameIndex=0,')
    replay = replace_once(replay, 'xp->step();', 'sc88voice::sourceBefore=frameIndex>=header.bootFrames ? &sourceBefore : nullptr;\n                sc88voice::sourceAfter=frameIndex>=header.bootFrames ? &sourceAfter : nullptr;\n                xp->step();')
    replay = replace_once(replay, 'controls.close();', 'controls.close(); sourceBefore.close(); sourceAfter.close(); sc88voice::sourceBefore=nullptr; sc88voice::sourceAfter=nullptr;')
    (OUT / "replay.cpp").write_text(replay, encoding="utf-8")
    print("SC88_VOICE_OBSERVATION_OVERLAY_COMPLETE")


if __name__ == "__main__":
    main()
