"""Separate control observations and parameter consumers from the pinned XP source."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "external/gearmulator/source/ronaldo"
OUT = ROOT / "build/offline-player-overlay"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Pinned control boundary changed: {old[:100]}")
    return text.replace(old, new, 1)


def control_block(text, first, last, stage, export):
    begin = text.index(first)
    end = text.index(last, begin)
    original = text[begin:end]
    if export:
        replacement = f"sc88param::compute({stage}, _voiceIndex, _voice, [&] {{\n{original}\n}});\n\t\t\t"
    else:
        replacement = f"sc88param::consume({stage}, _voiceIndex, _voice, [&](uint8_t reason) {{ raiseVoiceRampTerminalEvent(_voiceIndex, sc88param::terminalControl(_voice, reason), reason); }});\n\t\t\t"
    return text[:begin] + replacement + text[end:]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for export, name in [(True, "export"), (False, "replay")]:
        voice = (SOURCE / "custom_chips/xp/xp_voice.cpp").read_text(encoding="utf-8")
        core = (SOURCE / "custom_chips/xp/xp.cpp").read_text(encoding="utf-8")
        voice = replace_once(voice, '#include "xp.h"', '#include "xp.h"\n#include "parameter.h"')
        core = replace_once(core, '#include "xp.h"', '#include "xp.h"\n#include "parameter.h"')
        voice = control_block(voice, "const auto pitch = _voice.pitchCurrent_1b00;", "_voice.playbackStateConfig_1000 = playbackStarting", 1, export)
        voice = control_block(voice, "const auto target = _voice.tvfFDestination_1300 & ~rampAcknowledge;", "_voice.playbackStateConfig_1000 = playbackRunning", 2, export)
        refresh = "_voice.pitchIncrement_0d00 = decodePitch(_voice.pitchCurrent_1b00);\n\t\t\t\t_voice.tvfFCoefficient_2200 = (decodePitch(_voice.tvfFCurrent_1c00) << 2) & rampScratchMask;"
        if voice.count(refresh) != 1:
            raise ValueError("Halted source refresh boundary changed")
        if export:
            replacement = "sc88param::compute(3, _voiceIndex, _voice, [&] { " + refresh + " });"
        else:
            replacement = "sc88param::consume(3, _voiceIndex, _voice, [&](uint8_t reason) { raiseVoiceRampTerminalEvent(_voiceIndex, sc88param::terminalControl(_voice, reason), reason); });"
        voice = voice.replace(refresh, replacement, 1)
        refresh = refresh.replace("\n\t\t\t\t", "\n\t\t\t")
        replacement = replacement.replace("\n\t\t\t\t", "\n\t\t\t")
        voice = replace_once(voice, refresh, replacement)
        core = control_block(core, "const auto playbackCounter = static_cast<uint8_t>(_voice.playbackStateConfig_1000 & 7);", "\n\t}\n\n\tint32_t XP::stepVoiceFilter", 4, export)
        if export:
            first = "\tvoid XP::raiseVoiceRampTerminalEvent(const size_t _voiceIndex, uint32_t& _control, const uint8_t _reason)\n\t{"
            start = core.index(first) + len(first)
            end = core.index("\n\t}\n\n\tvoid XP::raiseVoiceMuteEvent", start)
            body = core[start:end]
            arbitration = body.index("\n\t\tif (!acceptVoiceEvent")
            core = core[:start] + body[:arbitration] + "\n\t\tsc88param::attempt(_voiceIndex, _reason, [&] {" + body[arbitration:] + "\n\t\t});" + core[end:]
        else:
            for forbidden in ["decodePitch(", "combineAmp(", "stepLinearRamp(", "stepLogRamp(", "calculateLinearRampStep("]:
                if forbidden in voice + core:
                    raise ValueError(f"Runtime still contains control calculation: {forbidden}")
        (OUT / f"xp_voice_{name}.cpp").write_text(voice, encoding="utf-8")
        (OUT / f"xp_{name}.cpp").write_text(core, encoding="utf-8")

    header = (SOURCE / "88emu/88lib/boards/sc88pro.h").read_text(encoding="utf-8")
    header = replace_once(header, "\tprotected:\n", "\tpublic:\n\t\txpLib::XP& traceXp() { return m_xp; }\n\t\tLsp& traceLsp() { return m_lsp; }\n\t\tbool traceReturnGate() const { return m_lspReturnEnabled; }\n\tprotected:\n")
    board = (SOURCE / "88emu/88lib/boards/sc88pro.cpp").read_text(encoding="utf-8")
    board = '#include "parameter.h"\n' + board
    board = replace_once(board, "\t\treturn v;\n\t}\n\n\tvoid Sc88Pro::extWrite8", "\t\tif(page == PageXp || page == PageLsp)\n\t\t\tsc88param::access(false, page == PageXp ? 1 : 2, off, v);\n\t\treturn v;\n\t}\n\n\tvoid Sc88Pro::extWrite8")
    anchor = "\tvoid Sc88Pro::extWrite8(const uint32_t _addr, const uint8_t _val)\n\t{"
    board = replace_once(board, anchor, anchor + "\n\t\tif((_addr >> 16) == PageXp || (_addr >> 16) == PageLsp)\n\t\t\tsc88param::access(true, (_addr >> 16) == PageXp ? 1 : 2, static_cast<uint16_t>(_addr), _val);")
    board = replace_once(board, "\t\t\tconst auto pending = m_xp.interruptState();", "\t\t\tconst auto pending = m_xp.interruptState();\n\t\t\tsc88param::irqRead(pending);")
    board = replace_once(board, "\t\t\tm_p3dr = _val;", "\t\t\tsc88param::returnGate(_val);\n\t\t\tm_p3dr = _val;")
    board = replace_once(board, "\t\tpowerCycle();\n\t}\n\n\t//", "\t\tpowerCycle();\n\t\tsc88param::reset(m_xp, m_lsp, m_lspReturnEnabled);\n\t}\n\n\t//")
    board = replace_once(board, "\t\treturn newOutput;", "\t\tsc88param::frame(m_xp, m_lsp, m_lspReturnEnabled);\n\t\treturn newOutput;")
    destination = OUT / "88lib/boards"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "sc88pro.h").write_text(header, encoding="utf-8")
    (OUT / "sc88pro.cpp").write_text(board, encoding="utf-8")
    main_cpp = (ROOT / "host/reference_runner/main.cpp").read_text(encoding="utf-8")
    main_cpp = main_cpp.replace("SC88_TRACE_EXPORT", "SC88_PARAMETER_EXPORT").replace('#include "trace.h"', '#include "parameter.h"').replace("sc88trace::", "sc88param::").replace('outDir / "register.trace"', 'outDir / "song.scp"')
    main_cpp = replace_once(main_cpp, "if (argc != 7)", "if (argc != 7 && argc != 8)")
    main_cpp = replace_once(main_cpp, 'sc88param::Writer trace(outDir / "song.scp", bootFrames, caseFrames, argv[6]);', 'sc88param::Writer trace(outDir / "song.scp", bootFrames, caseFrames, argv[6], argc == 8 ? std::stoull(argv[7]) : 0);')
    main_cpp = main_cpp.replace("Usage: sc88_reference_runner ROM_DIR EVENTS_OR_MID OUT_DIR BOOT_FRAMES CASE_FRAMES UPSTREAM_COMMIT", "Usage: sc88_parameter_export ROM_DIR EVENTS_OR_MID OUT_DIR BOOT_FRAMES CASE_FRAMES UPSTREAM_COMMIT [TAIL_FRAMES]").replace("SC88_REFERENCE_COMPLETE", "SC88_PARAMETER_EXPORT_COMPLETE")
    (OUT / "main.cpp").write_text(main_cpp, encoding="utf-8")
    print("Generated control observation and calculation-free replay sources")


if __name__ == "__main__":
    main()
