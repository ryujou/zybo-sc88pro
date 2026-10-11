"""Observe PC control hooks alongside the fixed Voice numerical probes."""
import prepare_voice_probe as observation
from prepare_offline_player import control_block, replace_once

ROOT = observation.ROOT
OUT = ROOT / "build/parameter-voice-overlay"


def main():
    observation.main()
    OUT.mkdir(parents=True, exist_ok=True)
    voice = (observation.OUT / "xp_voice.cpp").read_text(encoding="utf-8")
    core = (observation.OUT / "xp.cpp").read_text(encoding="utf-8")
    for first, last, stage in [
        ("const auto pitch = _voice.pitchCurrent_1b00;", "_voice.playbackStateConfig_1000 = playbackStarting", 1),
        ("const auto target = _voice.tvfFDestination_1300 & ~rampAcknowledge;", "_voice.playbackStateConfig_1000 = playbackRunning", 2),
    ]:
        voice = control_block(voice, first, last, stage, True)
    refresh = "_voice.pitchIncrement_0d00 = decodePitch(_voice.pitchCurrent_1b00);\n\t\t\t\t_voice.tvfFCoefficient_2200 = (decodePitch(_voice.tvfFCurrent_1c00) << 2) & rampScratchMask;"
    for indent in ["\t\t\t\t", "\t\t\t"]:
        block = refresh.replace("\t\t\t\t", indent)
        voice = replace_once(voice, block, "sc88param::compute(3, _voiceIndex, _voice, [&] { " + block + " });")
    core = control_block(core, "const auto playbackCounter = static_cast<uint8_t>(_voice.playbackStateConfig_1000 & 7);", "\n\t}\n\n\tint32_t XP::stepVoiceFilter", 4, True)
    marker = "\n\t\tif (!acceptVoiceEvent(_voiceIndex, _reason))"
    start = core.index("void XP::raiseVoiceRampTerminalEvent")
    pos = core.index(marker, start)
    core = core[:pos] + "\n\t\tsc88rtlparam::candidate = _reason;" + core[pos:]
    for name, text in [("xp_voice.cpp", voice), ("xp.cpp", core)]:
        text = text.replace("sc88param::compute", "sc88rtlparam::compute")
        text = replace_once(text, '#include "voice_probe.h"', '#include "voice_probe.h"\n#include "parameter_voice_probe.h"')
        if name == "xp.cpp":
            boundary = "\n\t\t}\n\n\t\tconst auto dspRunning"
            assert text.count(boundary) == 1
            end = text.index(boundary)
            text = text[:end] + "\n\t\t\tsc88rtlparam::command(m_state, paired ? voiceIndex - 1 : voiceIndex, paired, m_irqEventAcceptedThisStep);" + text[end:]
        (OUT / name).write_text(text, encoding="utf-8")
    main_cpp = (ROOT / "host/voice_reference/main.cpp").read_text(encoding="utf-8")
    main_cpp = replace_once(main_cpp, '#include "voice_probe.h"', '#include "voice_probe.h"\n#include "parameter_voice_probe.h"')
    main_cpp = replace_once(main_cpp, 'events << "frame,event,value\\n";', 'events << "frame,event,value\\n";\n            std::ofstream parameters(path/"parameters.csv"); sc88rtlparam::open(parameters);')
    main_cpp = replace_once(main_cpp, "sc88voice::romReads=nullptr; sc88voice::stages=nullptr;", "sc88rtlparam::output=nullptr;\n            sc88voice::romReads=nullptr; sc88voice::stages=nullptr;")
    (OUT / "main.cpp").write_text(main_cpp, encoding="utf-8")
    multi = (ROOT / "host/voice_reference/multivoice_vectors.cpp").read_text(encoding="utf-8")
    multi = replace_once(multi, '#include "voice_probe.h"', '#include "voice_probe.h"\n#include "parameter_voice_probe.h"')
    multi = replace_once(multi, 'events<<"frame,event,value\\n";', 'events<<"frame,event,value\\n";\n            auto parameters=open("parameters.csv"); sc88rtlparam::open(parameters);')
    multi = replace_once(multi, 'sc88voice::romReads=nullptr;', 'sc88rtlparam::output=nullptr; sc88voice::romReads=nullptr;')
    (OUT / "multivoice.cpp").write_text(multi, encoding="utf-8")
    replay = (observation.OUT / "replay.cpp").read_text(encoding="utf-8")
    replay = replace_once(replay, '#include "voice_probe.h"', '#include "voice_probe.h"\n#include "parameter_voice_probe.h"')
    replay = replace_once(replay, 'sc88voice::stageHeader(stages);', 'sc88voice::stageHeader(stages);\n        std::ofstream parameters(out/"parameters.csv"); sc88rtlparam::open(parameters);')
    replay = replace_once(replay, 'xp->step();', 'sc88rtlparam::output=frameIndex>=header.bootFrames ? &parameters : nullptr;\n                xp->step();')
    (OUT / "replay.cpp").write_text(replay, encoding="utf-8")
    fixture = (ROOT / "host/offline_irq_probe.cpp").read_text(encoding="utf-8")
    fixture = fixture[fixture.index("void fixture("):fixture.index("\nvoid observe(")]
    irq = (ROOT / "host/voice_reference/parameter_irq_vectors.cpp").read_text(encoding="utf-8")
    irq = irq.replace("// FIXED_IRQ_FIXTURE", fixture)
    (OUT / "irq_vectors.cpp").write_text(irq, encoding="utf-8")
    print("SC88_PARAMETER_VOICE_OBSERVATION_COMPLETE")


if __name__ == "__main__":
    main()
