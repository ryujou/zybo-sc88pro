// SPDX-License-Identifier: GPL-3.0-only
#include "parameter.h"
#include "sc88_parameter_effects.h"
#include "trace.h"
#include "common/romDescramble.h"
#include "baseLib/md5.h"
#include <chrono>
#include <cstring>
#include <iostream>
#include <iterator>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace fs=std::filesystem;
using namespace sc88param;

std::vector<uint8_t> loadWaves(const fs::path& directory)
{
    const size_t sizes[]={8388608,8388608,4194304};
    const char* ids[]={"bd33b20bb5e8f51e436e141f81a75c14", "125ea2056dc208f04a141b3dcdffdb1b", "48c3887c9a2a574b907242640fa0a320"};
    std::vector<uint8_t> raw;
    for (int i=0; i<3; ++i)
    {
        const auto path=directory/("sc88pro_wave"+std::to_string(i)+".bin");
        std::ifstream stream(path,std::ios::binary);
        if (!stream) throw std::runtime_error("Cannot open Wave ROM: "+path.string());
        std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(stream), {}};
        if (bytes.size()!=sizes[i] || baseLib::MD5(bytes).toString()!=ids[i]) throw std::runtime_error("Wave ROM Registry mismatch");
        raw.insert(raw.end(),bytes.begin(),bytes.end());
    }
    std::vector<uint8_t> decoded(raw.size());
    rLib::rom::Pcm16::descramble(raw.data(),raw.size(),decoded.data(),decoded.size());
    return decoded;
}

class Assertions
{
public:
    explicit Assertions(const char* path)
    {
        if (!path) return;
        input.open(path,std::ios::binary);
        char magic[8]{}; input.read(magic,8);
        if (!input || std::memcmp(magic,"SC88AST1",8)) throw std::runtime_error("Invalid assertion sidecar");
        enabled=true;
    }
    void readback(const Event& event, uint16_t address, uint8_t actual)
    {
        if (!enabled) return;
        const auto h=record();
        if (h.frame!=event.frame || h.sequence!=event.sequence || h.kind!=Read || h.target!=event.target || h.address!=address || h.bytes)
            throw std::runtime_error("Read assertion position mismatch");
        if (h.value!=actual) throw std::runtime_error("Read result mismatch frame="+std::to_string(event.frame)+" stage=HOST target="+std::to_string(event.target)+" address="+std::to_string(address)+" sequence="+std::to_string(event.sequence)+" reference="+std::to_string(h.value)+" actual="+std::to_string(actual));
        ++reads;
    }
    void checkpoint(uint64_t frame, const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
    {
        if (!enabled) return;
        const auto h=record(); const auto state=sc88trace::probe(xp,lsp,gate);
        if (h.kind!=10 || h.frame!=frame || h.sequence || h.target || h.address || h.value || h.bytes!=state.words.size()*8)
            throw std::runtime_error("State assertion position/size mismatch frame="+std::to_string(frame));
        std::vector<uint64_t> expected(state.words.size());
        input.read(reinterpret_cast<char*>(expected.data()),h.bytes);
        if (!input) throw std::runtime_error("Truncated state assertion");
        if (expected!=state.words)
        {
            const auto named=sc88trace::probe(xp,lsp,gate,true);
            for (size_t i=0; i<expected.size(); ++i) if (expected[i]!=state.words[i])
            {
                std::ostringstream message;
                message << "State mismatch frame=" << frame << " stage=completed_frame field=" << named.labels[i] << " reference=" << expected[i] << " actual=" << state.words[i]
                    << " reference_hex=0x" << std::hex << expected[i] << " actual_hex=0x" << state.words[i];
                throw std::runtime_error(message.str());
            }
        }
        ++checkpoints;
    }
    void finish()
    {
        if (enabled && input.peek()!=std::char_traits<char>::eof()) throw std::runtime_error("Trailing/missing assertion consumers");
    }
    uint64_t checkpoints=0, reads=0;
private:
    struct Record { uint64_t frame; uint32_t sequence; uint8_t kind,target; uint16_t address; uint32_t value,bytes; };
    Record record()
    {
        uint8_t b[24]{}; input.read(reinterpret_cast<char*>(b),24);
        if (!input) throw std::runtime_error("Missing assertion / incomplete sidecar");
        const auto get=[&](unsigned p,unsigned n) { uint64_t v=0; for(unsigned i=0;i<n;++i) v|=uint64_t{b[p+i]}<<(i*8); return v; };
        return {get(0,8),static_cast<uint32_t>(get(8,4)),b[12],b[13],static_cast<uint16_t>(get(14,2)),static_cast<uint32_t>(get(16,4)),static_cast<uint32_t>(get(20,4))};
    }
    std::ifstream input;
    bool enabled=false;
};

int main(int argc,char** argv)
{
    try
    {
        if (argc==4 && std::string(argv[1])=="--scan")
        {
            Reader reader(argv[2],argv[3]);
            uint64_t bytes=0,nativeBytes=0,frameBytes=0,peakFrameBytes=0,deltaEvents=0,terminalEvents=0,windowBytes=0,peak16Bytes=0;
            uint64_t peakFrameIndex=0,peak16FirstFrame=0;
            bool resetSeen=false,endSeen=false;
            const auto begin=std::chrono::steady_clock::now();
            while(!endSeen)
            {
                const auto event=reader.take();
                if(!resetSeen && event.kind!=Reset) throw std::runtime_error("RESET must be first");
                const auto eventBytes=24+event.payload.size(); bytes+=eventBytes; frameBytes+=eventBytes;
                if(event.frame>=reader.header.bootFrames) nativeBytes+=eventBytes;
                if(event.kind==Reset) { if(resetSeen || reader.records!=1) throw std::runtime_error("Duplicate RESET"); resetSeen=true; }
                if(event.kind==Delta) ++deltaEvents;
                if(event.kind==Terminal) ++terminalEvents;
                if(event.kind==Frame)
                {
                    if(frameBytes>peakFrameBytes) { peakFrameBytes=frameBytes; peakFrameIndex=reader.frameIndex; }
                    windowBytes+=frameBytes; frameBytes=0; reader.nextFrame();
                    if(reader.frameIndex%16==0) { if(windowBytes>peak16Bytes) { peak16Bytes=windowBytes; peak16FirstFrame=reader.frameIndex-16; } windowBytes=0; }
                }
                if(event.kind==End) { if(reader.frameIndex!=reader.header.bootFrames+reader.header.caseFrames) throw std::runtime_error("Early END"); endSeen=true; }
            }
            reader.finish();
            if(windowBytes>peak16Bytes) { peak16Bytes=windowBytes; peak16FirstFrame=reader.frameIndex&~uint64_t(15); }
            const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
            std::cout << "{\"success\":true,\"frames\":" << reader.frameIndex << ",\"records\":" << reader.records << ",\"event_bytes\":" << bytes << ",\"native_event_bytes\":" << nativeBytes << ",\"native_average_event_bytes_per_second\":" << nativeBytes*32000.0/reader.header.caseFrames
                << ",\"peak_frame_event_bytes\":" << peakFrameBytes << ",\"peak_frame_index\":" << peakFrameIndex << ",\"peak_aligned_16_frame_event_bytes\":" << peak16Bytes << ",\"peak_aligned_16_first_frame\":" << peak16FirstFrame << ",\"logical_blocks\":" << reader.logicalBlocks << ",\"largest_block_bytes\":" << reader.largestBlockBytes
                << ",\"decoder_peak_buffer_capacity_bytes_x64\":" << reader.peakBufferCapacity
                << ",\"delta_events\":" << deltaEvents << ",\"terminal_events\":" << terminalEvents << ",\"decode_seconds_x64\":" << seconds << ",\"decode_bytes_per_second_x64\":" << bytes/seconds << ",\"ARMv7\":\"UNVERIFIED\",\"USB\":\"UNVERIFIED\"}\n";
            return 0;
        }
        if (argc!=5 && argc!=6) throw std::runtime_error("Usage: sc88_parameter_replay WAVE_ROM_DIR PARAMETERS OUT_DIR COMMIT [ASSERTIONS]");
        auto waves=loadWaves(argv[1]);
        auto xp=std::make_unique<xpLib::XP>(); auto lsp=std::make_unique<lspLib::LSPDispatcher>();
        auto effects=std::make_unique<Sc88ParameterEffects>();
        for (size_t i=0;i<5;++i) xp->mapWaveRom(i,waves.data()+i*4194304,4194304,xpLib::XP::PhysicalWaveRomWidth::bits16);
        Reader reader(argv[2],argv[4]); replay=&reader;
        Assertions assertions(argc==6 ? argv[5] : nullptr);
        const fs::path out(argv[3]); fs::create_directories(out);
        std::ofstream boot(out/"boot.pcm",std::ios::binary), pcm(out/"native.pcm",std::ios::binary);
        boot.exceptions(std::ios::badbit|std::ios::failbit); pcm.exceptions(std::ios::badbit|std::ios::failbit);
        uint64_t writes=0,reads=0,lspActive=0,lspInput=0,nonzeroReturns=0;
        bool resetSeen=false,gate=false,endSeen=false;
        const auto begin=std::chrono::steady_clock::now();
        while (!endSeen)
        {
            const auto& next=reader.peek();
            if (!resetSeen && next.kind!=Reset) throw std::runtime_error("Cold RESET must be first");
            if (reader.frameIndex==reader.header.bootFrames+reader.header.caseFrames && next.kind!=End) throw std::runtime_error("Expected END at exact duration");
            if (next.kind==Delta || next.kind==Terminal || next.kind==Frame)
            {
                // Feed the PS boundary with ordered sends only, never DSP history or reference PCM.
                uint64_t sends[256];
                const unsigned voices=(xp->state().highestVoice&63)+1;
                for(unsigned v=0;v<voices;++v) for(unsigned s=0;s<4;++s) {
                    const auto& voice=xp->state().voices[v];
                    const int32_t output=int32_t(voice.filterOutput_2a00&0x7fffff)-int32_t(voice.filterOutput_2a00&0x800000);
                    const auto route=voice.mixer_3a00[s];
                    const int64_t contribution=(int64_t(output)*(route>>6))/512;
                    const unsigned slot=v*4+s;
                    sends[slot]=(uint64_t(slot+(s==1 ? 1 : 0))<<54)|(uint64_t(v)<<48)|(uint64_t(s)<<46)|
                                (uint64_t(route&63)<<40)|(uint64_t(contribution)&0x1ffffff);
                }
                uint64_t effectStereo=0;
                if(effects->process(sends,voices*4,effectStereo)) throw std::runtime_error("PS effect send layout mismatch");
                xp->step();
                if (reader.peek().kind!=Frame)
                {
                    const auto& pending=reader.peek();
                    throw std::runtime_error("Unconsumed/mispositioned control parameter frame="+std::to_string(reader.frameIndex)+" stage="+std::to_string(pending.stage)+" voice="+std::to_string(pending.voice)+" mask="+std::to_string(pending.mask)+" expected_kind=5 actual_kind="+std::to_string(pending.kind));
                }
                reader.take();
                auto& dsp=xp->dsp();
                const auto& busB=dsp.serialOutput(xpLib::Dsp::SerialBus::b);
                const auto& busC=dsp.serialOutput(xpLib::Dsp::SerialBus::c);
                const auto count=dsp.serialOutputCount(xpLib::Dsp::SerialBus::b);
                const int32_t sample[2]={dsp.serialOutputCount(xpLib::Dsp::SerialBus::c)>=2 ? busC[0] : 0,dsp.serialOutputCount(xpLib::Dsp::SerialBus::c)>=2 ? busC[1] : 0};
                if(effectStereo!=(uint32_t(sample[0])|(uint64_t(uint32_t(sample[1]))<<32)))
                    throw std::runtime_error("PS effect PCM mismatch frame="+std::to_string(reader.frameIndex));
                const lspLib::LSPDispatcher::SampleFrame send{count>0 ? busB[0] : 0,count>1 ? busB[1] : 0};
                if (lsp->running() && lsp->hasProgram()) ++lspActive;
                if (send.first || send.second) ++lspInput;
                const auto result=lsp->process(send);
                std::array<int32_t,2> returns{}; if(gate) returns={result.first>>8,result.second>>8};
                if (returns[0] || returns[1]) ++nonzeroReturns;
                dsp.setSerialInput(xpLib::Dsp::SerialBus::a,returns.data(),returns.size());
                (reader.frameIndex<reader.header.bootFrames ? boot : pcm).write(reinterpret_cast<const char*>(sample),sizeof(sample));
                reader.nextFrame();
                if (reader.frameIndex%32768==0) assertions.checkpoint(reader.frameIndex,*xp,*lsp,gate);
                continue;
            }
            const auto event=reader.take();
            if(event.kind>=Reset && event.kind<=Gate) {
                const unsigned address=(event.kind==Write || event.kind==Read) ? event.payload[0]|(unsigned(event.payload[1])<<8) : 0;
                const unsigned value=event.kind==Write ? event.payload[2] : event.kind==Gate ? event.payload[0] : 0;
                effects->control(event.kind|(uint64_t(event.target)<<8)|(uint64_t(address)<<16)|(uint64_t(value)<<32));
            }
            switch(event.kind)
            {
            case Reset:
                if (resetSeen || reader.records!=1 || reader.frameIndex) throw std::runtime_error("Duplicate/mispositioned RESET");
                xp->reset(); lsp->clear(); gate=false; resetSeen=true;
                assertions.checkpoint(0,*xp,*lsp,gate); break;
            case Write: case Read:
            {
                const auto address=static_cast<uint16_t>(event.payload[0]|(event.payload[1]<<8));
                if (event.kind==Write)
                {
                    if (event.target==1) xp->hostWrite8(address,event.payload[2]); else lsp->hostWrite(address,event.payload[2]); ++writes;
                }
                else
                {
                    const auto value=static_cast<uint8_t>(!event.target ? xp->interruptState() ? 0xfd : 0xff : event.target==1 ? xp->hostRead8(address) : lsp->hostRead(address));
                    assertions.readback(event,address,value); ++reads;
                }
                break;
            }
            case Gate: gate=(event.payload[0]&128)!=0; break;
            case End:
                if (reader.frameIndex!=reader.header.bootFrames+reader.header.caseFrames) throw std::runtime_error("Early END");
                assertions.checkpoint(reader.frameIndex,*xp,*lsp,gate); endSeen=true; break;
            default: throw std::runtime_error("Unexpected parameter stage/event");
            }
        }
        reader.finish(); assertions.finish(); replay=nullptr; boot.close(); pcm.close();
        const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
        std::ofstream report(out/"replay.json"); report.exceptions(std::ios::badbit|std::ios::failbit);
        report << "{\"success\":true,\"scope\":\"offline_parameter_player_software\",\"cpu_instructions\":0,\"control_rom_loaded\":false,\"control_implementations_executed\":0,\"frames\":" << reader.frameIndex
            << ",\"ps_effect_boundary_exact_frames\":" << reader.frameIndex << ",\"ps_effect_hardware_verified\":false"
            << ",\"records\":" << reader.records << ",\"writes\":" << writes << ",\"reads\":" << reads << ",\"state_checkpoints\":" << assertions.checkpoints << ",\"lsp_active_frames\":" << lspActive << ",\"lsp_input_frames\":" << lspInput << ",\"lsp_return_frames\":" << nonzeroReturns << ",\"replay_seconds_x64\":" << seconds << "}\n";
        std::cout << "SC88_PARAMETER_REPLAY_COMPLETE frames=" << reader.frameIndex << " state_checkpoints=" << assertions.checkpoints << '\n';
        return 0;
    }
    catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
