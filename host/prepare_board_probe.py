"""Observe a bounded real MIDI Trace window; never restore runtime state from goldens."""
from prepare_voice_probe import ROOT,replace_once


def main():
    out=ROOT/"build/board-overlay";out.mkdir(parents=True,exist_ok=True)
    source=(ROOT/"host/trace/replay.cpp").read_text(encoding="utf-8")
    source=replace_once(source,'#include "trace.h"','#include "trace.h"\n#include "voice_probe.h"')
    source=replace_once(source,'if (argc!=5)','if (argc!=7)')
    source=replace_once(source,'OUT_DIR UPSTREAM_COMMIT','OUT_DIR UPSTREAM_COMMIT FIRST_FRAME FRAME_COUNT')
    source=replace_once(source,'auto waves=loadWaves(argv[1]);',
        'const uint64_t captureFirst=std::stoull(argv[5]), captureCount=std::stoull(argv[6]);\n'
        '        const uint64_t captureEnd=captureFirst+captureCount;\n'
        '        if (!captureCount || captureCount>32768 || captureEnd<captureFirst) throw std::runtime_error("Invalid capture interval");\n'
        '        auto waves=loadWaves(argv[1]);')
    source=replace_once(source,'const fs::path out(argv[3]);',
        'if(captureFirst<header.bootFrames || captureEnd>header.bootFrames+header.caseFrames) throw std::runtime_error("Capture outside MIDI timeline");\n'
        '        const fs::path out(argv[3]);')
    source=replace_once(source,'fs::create_directories(out);',
        'fs::create_directories(out);\n'
        '        std::ofstream waveImage(out/"decoded-wave.bin",std::ios::binary); waveImage.exceptions(std::ios::badbit|std::ios::failbit);\n'
        '        waveImage.write(reinterpret_cast<const char*>(waves.data()),waves.size()); waveImage.close();')
    source=replace_once(source,'std::ofstream boot(out/"boot.pcm",std::ios::binary), pcm(out/"native.pcm",std::ios::binary);',
        'std::ofstream pcm(out/"reference.pcm",std::ios::binary);')
    source=replace_once(source,'boot.exceptions(std::ios::badbit|std::ios::failbit);','')
    source=replace_once(source,'uint64_t frameIndex=0,',r'''auto open=[&](const char* name) { std::ofstream f(out/name); f.exceptions(std::ios::badbit|std::ios::failbit); return f; };
        auto initial=open("initial.csv"), states=open("expected.csv"), controls=open("events.csv"), rom=open("rom-reads.csv"), sends=open("sends.csv"), mixes=open("mix.csv");
        sc88voice::csvHeader(initial,xp->state(),0,64); sc88voice::csvHeader(states,xp->state(),0,64);
        sc88voice::romHeader(rom); controls<<"frame,event,value\n";
        sends<<"frame,voice,send,slot,destination,contribution\n";
        mixes<<"frame,bank,seen"; for(unsigned i=0;i<64;++i) mixes<<",cell["<<i<<']'; mixes<<'\n';
        std::map<std::string,uint64_t> previous;
        sc88voice::observedVoiceCount=64;
        uint64_t frameIndex=0,''')
    source=replace_once(source,'while (!endSeen)','while (!endSeen && frameIndex<captureEnd)')
    source=replace_once(source,'xp->step();',r'''const bool capturing=frameIndex>=captureFirst;
                if(capturing)
                {
                    if((xp->state().highestVoice&63)!=63) fail("Board window requires 64 Voice schedule");
                    if(frameIndex==captureFirst) sc88voice::csvRow(initial,xp->state(),frameIndex,0,64);
                    else sc88voice::fields(xp->state(),frameIndex,[&](const std::string& key,uint64_t value) {
                        if(key=="frame" || key=="irqBlockedEvent") return;
                        if(key=="sampleClock") { if(value!=previous.at(key)) fail("External sample clock change"); return; }
                        if(value!=previous.at(key)) controls<<frameIndex<<','<<key<<','<<value<<'\n';
                    },0,64);
                    sc88voice::observedFrame=frameIndex; sc88voice::observedVoices=xp->state().voices.data();
                    sc88voice::romReads=&rom;sc88voice::mixerSends=&sends;sc88voice::mixerCells=&mixes;
                }
                xp->step();
                if(capturing)
                {
                    sc88voice::csvRow(states,xp->state(),frameIndex,0,64);
                    sc88voice::fields(xp->state(),frameIndex,[&](const std::string& key,uint64_t value) { previous[key]=value; },0,64);
                }''')
    source=replace_once(source,'(frameIndex<header.bootFrames ? boot : pcm).write', 'if(capturing) pcm.write')
    source=replace_once(source,'if (input.peek()!=std::char_traits<char>::eof()) throw std::runtime_error("Trailing Trace records after END");',
        'if(frameIndex!=captureEnd) throw std::runtime_error("Trace ended before capture completed");')
    source=replace_once(source,'boot.close(); pcm.close();','pcm.close(); initial.close(); states.close(); controls.close(); rom.close(); sends.close(); mixes.close();')
    source=replace_once(source,'std::cout << "SC88_REPLAY_COMPLETE frames="',
        'std::cout << "SC88_BOARD_CAPTURE first=" << captureFirst << " count=" << captureCount << " reads=" << sc88voice::romReadCount << "\\n";\n        std::cout << "SC88_REPLAY_PREFIX_COMPLETE frames="')
    (out/"replay.cpp").write_text(source,encoding="utf-8")
    print("SC88_BOARD_OBSERVATION_OVERLAY_COMPLETE")


if __name__=="__main__":main()
