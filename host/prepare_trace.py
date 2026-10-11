"""Generate an observation-only SC-88Pro build overlay; pinned source stays pristine."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "external/gearmulator/source/ronaldo/88emu/88lib/boards"
OUT = ROOT / "build/trace-overlay"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Pinned instrumentation anchor is not unique: {old}")
    return text.replace(old, new, 1)


def main():
    header = (SOURCE / "sc88pro.h").read_text()
    header = replace_once(header, "\tprotected:\n", "\tpublic:\n\t\txpLib::XP& traceXp() { return m_xp; }\n\t\tLsp& traceLsp() { return m_lsp; }\n\t\tbool traceReturnGate() const { return m_lspReturnEnabled; }\n\tprotected:\n")
    source = (SOURCE / "sc88pro.cpp").read_text()
    source = '#include "trace.h"\n' + source
    source = replace_once(source, "\t\treturn v;\n\t}\n\n\tvoid Sc88Pro::extWrite8", "\t\tif(page == PageXp || page == PageLsp)\n\t\t\tsc88trace::access(false, page == PageXp ? 1 : 2, off, v);\n\t\treturn v;\n\t}\n\n\tvoid Sc88Pro::extWrite8")
    anchor = "\tvoid Sc88Pro::extWrite8(const uint32_t _addr, const uint8_t _val)\n\t{"
    source = replace_once(source, anchor, anchor + "\n\t\tif((_addr >> 16) == PageXp || (_addr >> 16) == PageLsp)\n\t\t\tsc88trace::access(true, (_addr >> 16) == PageXp ? 1 : 2, static_cast<uint16_t>(_addr), _val);")
    source = replace_once(source, "\t\t\tconst auto pending = m_xp.interruptState();", "\t\t\tconst auto pending = m_xp.interruptState();\n\t\t\tsc88trace::irqRead(pending);")
    source = replace_once(source, "\t\t\tm_p3dr = _val;", "\t\t\tsc88trace::returnGate(_val);\n\t\t\tm_p3dr = _val;")
    source = replace_once(source, "\t\tpowerCycle();\n\t}\n\n\t//", "\t\tpowerCycle();\n\t\tsc88trace::reset(m_xp, m_lsp, m_lspReturnEnabled);\n\t}\n\n\t//")
    source = replace_once(source, "\t\treturn newOutput;", "\t\tsc88trace::frame(m_xp, m_lsp, m_lspReturnEnabled);\n\t\treturn newOutput;")
    destination = OUT / "88lib/boards"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "sc88pro.h").write_text(header, encoding="utf-8")
    (OUT / "sc88pro.cpp").write_text(source, encoding="utf-8")
    print("Generated trace observation overlay (no numerical/CPU scheduling changes)")


if __name__ == "__main__":
    main()
