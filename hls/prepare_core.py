"""GPL-3.0-only. Mechanical, bounded HLS port of the pinned XP Voice mathematics."""
import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "external/gearmulator/source/ronaldo/custom_chips/xp"
OUT = ROOT / "build/hls-source"
CONTRACT = json.loads((ROOT / "reference/phase2-contract.json").read_text(encoding="utf-8"))


def function(text, name):
    match = re.search(r"(?m)^\t[^\n]* XP::"+name+r"\(",text)
    assert match, name
    start = match.start()
    brace = text.index("{",start)
    level = 1
    end = brace + 1
    while level:
        level += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end], text[start:brace].strip()


def once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old,new)


STREAM_METHODS = ["stepVoiceSource","refillVoiceCell","refillVoicePair","readVoiceSampleFromCache","readExponentCache","refreshExponentCacheAfterAdvance","advanceVoiceAddress","readVoiceWaveByte"]


def stream_arguments(text, declarations=False):
    matches = list(re.finditer(r"\b("+"|".join(STREAM_METHODS)+r")\(",text))
    for match in reversed(matches):
        end=match.end(); depth=1
        while depth:
            depth += (text[end]=="(")-(text[end]==")")
            end+=1
        extra = ", hls::stream<uint32_t>& requests, hls::stream<uint8_t>& replies" if declarations else ", requests, replies"
        text=text[:end-1]+extra+text[end-1:]
    return text


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    original_header = (SOURCE / "xp.h").read_text(encoding="utf-8")
    types = original_header[original_header.index("\t\tstruct WaveControl"):original_header.index("\t\tstruct State")]
    types = types.replace("std::array<uint16_t, 8> waveCircularBuffer_0800{}", "uint16_t waveCircularBuffer_0800[8]{}")
    types = types.replace("std::array<uint16_t, 4> mixer_3a00{}", "uint16_t mixer_3a00[4]{}")
    common = (SOURCE / "xp_voice_common.h").read_text(encoding="utf-8")
    pitch = list(csv.DictReader((ROOT / "build/verification/phase-02/golden/pitch-table.csv").open(encoding="utf-8")))
    assert len(pitch) == 256
    table = "inline const std::array<uint16_t,256> pitchMantissa={{"+",".join(row["mantissa"] for row in pitch)+"}};"
    common,n = re.subn(r"inline const std::array<uint16_t, 256> pitchMantissa = \[\].*?\}\(\);",table,common,flags=re.S)
    assert n == 1
    common = common.replace('"xp.h"','"xp3_core.h"').replace('"../pcmInterpolation.h"','"pcmInterpolation.h"').replace("xpLib::xpInternal","xp3::xpInternal").replace("#include <cmath>","")
    (OUT / "pcmInterpolation.h").write_text((SOURCE.parent / "pcmInterpolation.h").read_text(encoding="utf-8"),encoding="utf-8")
    (OUT / "xp3_common.h").write_text(common,encoding="utf-8")
    names_voice = ["stepVoiceSource","voiceAddressRunsReverse","voiceUses16BitWaveBus","refillVoiceCell","refillVoicePair","readVoiceSampleFromCache","encodeVoiceSample","decodeVoiceDelta","interpolateVoice","readExponentCache","refreshExponentCacheAfterAdvance","advanceVoiceAddress"]
    names_misc = ["stepVoiceRamps","stepVoiceFilter","applyTva","stepPairedVoiceFilter","stepTvaGain","acceptVoiceEvent","raiseVoiceLoopMarkerEvent","raiseVoiceRampTerminalEvent","raiseVoiceMuteEvent"]
    declarations=[]
    functions=[]
    for source,names in [("xp_voice.cpp",names_voice),("xp.cpp",names_misc)]:
        text = (SOURCE / source).read_text(encoding="utf-8")
        for name in names:
            body,signature = function(text,name)
            directive = "INLINE" if name in STREAM_METHODS else "INLINE off"
            body = body.replace("{", "{\n#pragma HLS "+directive, 1)
            body = body.replace("_voice.waveCircularBuffer_0800.size()", "size_t{8}")
            declarations.append(stream_arguments(signature.replace("XP::",""),True)+";")
            brace=body.index("{")
            body=stream_arguments(body[:brace],True)+stream_arguments(body[brace:])
            if name == "stepVoiceSource":
                body = once(body,"for (size_t i = 0; i < preloadCount; ++i)","for (size_t i = 0; i < 8; ++i) if (i < preloadCount)")
                body = body.replace("for (uint32_t cell = 0; cell < cellCount; ++cell)","for (uint32_t cell = 0; cell < 4; ++cell) if (cell < cellCount)")
                body = once(body,"for (uint32_t pair = 0; pair < pairCount; ++pair)","for (uint32_t pair = 0; pair < 2; ++pair) if (pair < pairCount)")
            if name == "stepPairedVoiceFilter":
                body = once(body,"static_cast<int64_t>(_value) << booster","static_cast<int64_t>(_value) * (int64_t{1} << booster)")
            functions.append(body)
    header = """// SPDX-License-Identifier: GPL-3.0-only
// Numerical types and methods derived from the pinned Gearmulator XP. See THIRD_PARTY_NOTICES.md.
#pragma once
#include "xp3_voice.h"
#include <array>
#include <cstddef>
namespace xp3 {
class XP { public:
enum class PhysicalWaveRomWidth : uint8_t { bits8,bits16 };
""" + types + """
struct State {
    VoiceState voices[2]{};
    uint8_t waveRomConfig[8]{};
    uint64_t sampleClock=0;
    uint16_t irqStatus=0,irqConfigMask=0;
    bool interrupt=false,irqBlockedEvent=false;
};
struct VoiceStepResult { int32_t sample=0; bool filterDue=false; };
struct WaveRomView { uint32_t size=0; PhysicalWaveRomWidth width=PhysicalWaveRomWidth::bits8; uint8_t voiceBankShift=0; };
State m_state{};
WaveRomView m_waveRoms[8]{};
bool m_irqEventAcceptedThisStep=false;
uint8_t readVoiceWaveByte(const VoiceState&,uint32_t,hls::stream<uint32_t>& requests,hls::stream<uint8_t>& replies) const;
""" + "\n".join(declarations) + "\n};\n"
    # Preserve the Gate A CSV field order, not compiler object layout.
    fields = re.findall(r"F\(([\w.]+)\)",(ROOT / "host/voice_reference/voice_probe.h").read_text(encoding="utf-8").split("template<class F>")[0])
    fields += [f"waveCircularBuffer_0800[{i}]" for i in range(8)] + [f"mixer_3a00[{i}]" for i in range(4)]
    assert len(fields) == 51
    header += "inline void unpackVoice(XP::VoiceState& v,const uint32_t* data) {\n"
    for i,name in enumerate(fields):
        width = CONTRACT["state_widths"][name.split("[")[0]]
        cast = "uint16_t" if "[" in name else f"decltype(v.{name})"
        header += f"v.{name}=static_cast<{cast}>(data[{i}] & 0x{(1<<width)-1:x}u);\n"
    header += "}\ninline void packVoice(const XP::VoiceState& v,uint32_t* data) {\n"
    for i,name in enumerate(fields):
        header += f"data[{i}]=static_cast<uint32_t>(v.{name});\n"
    header += "}\n#ifndef __SYNTHESIS__\nstatic const char* const voiceFieldNames[51]={"+",".join('"'+name+'"' for name in fields)+"};\n#endif\n}\n"
    (OUT / "xp3_core.h").write_text(header,encoding="utf-8")
    code = """// SPDX-License-Identifier: GPL-3.0-only
// XP Chip Emulator derivatives. Thanks to NukeYKT, InfoSecDJ and the Gearmulator contributors.
#include "xp3_core.h"
#include "xp3_common.h"
namespace xp3 {
using namespace xpInternal;
uint8_t XP::readVoiceWaveByte(const VoiceState& voice,uint32_t source,hls::stream<uint32_t>& requests,hls::stream<uint8_t>& replies) const {
#pragma HLS INLINE
    const unsigned cs=(voice.waveControl_0000>>4)&7;
    const auto& rom=m_waveRoms[cs];
    const unsigned bank=(voice.waveControl_0000&15)>>rom.voiceBankShift;
    uint32_t address=source&0xfffff;
    if (!voiceUses16BitWaveBus(voice) && rom.width==PhysicalWaveRomWidth::bits16) address&=~1u;
    address|=bank<<20;
    if (address>=rom.size) return 0;
    requests.write((cs<<24)|address);
    return replies.read();
}
""" + "\n\n".join(functions) + "\n}\n"
    (OUT / "xp3_core.cpp").write_text(code,encoding="utf-8")
    (OUT / "field-order.json").write_text(json.dumps(fields,indent=2)+"\n",encoding="utf-8")
    print("XP3_HLS_SOURCE_COMPLETE bounded_preload=8 bounded_cells=4 bounded_pairs=2")


if __name__ == "__main__":
    main()
