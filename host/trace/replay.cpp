// SPDX-License-Identifier: GPL-3.0-only
#include "trace.h"
#include "common/romDescramble.h"
#include "baseLib/md5.h"
#include <cstring>
#include <iostream>
#include <iterator>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace fs=std::filesystem;
using namespace sc88trace;

std::vector<uint8_t> loadWaves(const fs::path& directory)
{
    const size_t sizes[]={8388608,8388608,4194304};
    const char* ids[]={"bd33b20bb5e8f51e436e141f81a75c14", "125ea2056dc208f04a141b3dcdffdb1b", "48c3887c9a2a574b907242640fa0a320"};
    std::vector<uint8_t> raw;
    for (int i=0; i<3; ++i)
    {
        const auto path=directory / ("sc88pro_wave"+std::to_string(i)+".bin");
        std::ifstream stream(path, std::ios::binary);
        if (!stream) throw std::runtime_error("Cannot open Wave ROM: "+path.string());
        std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(stream), {}};
        if (bytes.size()!=sizes[i] || baseLib::MD5(bytes).toString()!=ids[i]) throw std::runtime_error("Wave ROM Registry mismatch");
        raw.insert(raw.end(), bytes.begin(), bytes.end());
    }
    std::vector<uint8_t> decoded(raw.size());
    rLib::rom::Pcm16::descramble(raw.data(), raw.size(), decoded.data(), decoded.size());
    return decoded;
}

int main(int argc, char** argv)
{
    try
    {
        if (argc!=5) throw std::runtime_error("Usage: sc88_trace_replay WAVE_ROM_DIR TRACE OUT_DIR UPSTREAM_COMMIT");
        auto waves=loadWaves(argv[1]);
        auto xp=std::make_unique<xpLib::XP>();
        auto lsp=std::make_unique<lspLib::LSPDispatcher>();
        for (size_t i=0; i<5; ++i) xp->mapWaveRom(i, waves.data()+i*4194304, 4194304, xpLib::XP::PhysicalWaveRomWidth::bits16);
        std::ifstream input(argv[2], std::ios::binary);
        if (!input) throw std::runtime_error("Cannot open Trace");
        Header header{};
        input.read(reinterpret_cast<char*>(&header), sizeof(header));
        if (!input || std::memcmp(header.magic, "SC88TRC1", 8) || header.version!=1 || header.rate!=32000 || header.interval!=32768 || header.crc!=crc32(&header, 76) || std::string(header.commit,40)!=argv[4])
            throw std::runtime_error("Invalid Trace header/version/identity/CRC");
        if (!header.bootFrames || !header.caseFrames) throw std::runtime_error("Empty Trace duration");
        const fs::path out(argv[3]);
        fs::create_directories(out);
        std::ofstream boot(out/"boot.pcm",std::ios::binary), pcm(out/"native.pcm",std::ios::binary);
        boot.exceptions(std::ios::badbit|std::ios::failbit);
        pcm.exceptions(std::ios::badbit|std::ios::failbit);
        uint64_t frameIndex=0, records=0, reads=0, writes=0, irqReads=0, checkpoints=0, gateWrites=0, lspActive=0, lspInput=0, nonzeroReturns=0;
        uint32_t sequence=0;
        bool resetSeen=false, gate=false, endSeen=false, initialCheckpoint=false, checkpointDue=false;
        while (!endSeen)
        {
            Record r{};
            input.read(reinterpret_cast<char*>(&r), sizeof(r));
            if (!input) throw std::runtime_error("Truncated Trace / missing END");
            std::ostringstream where;
            where << "frame=" << r.frame << " sequence=" << r.sequence << " event=" << records << " kind=" << unsigned(r.kind) << " chip=" << unsigned(r.chip) << " address=0x" << std::hex << r.address;
            const auto fail=[&](const std::string& message) { throw std::runtime_error(message+"; "+where.str()); };
            if (r.frame!=frameIndex || r.sequence!=sequence++) fail("Frame/sequence order mismatch");
            uint32_t check=crc32(&r,20);
            std::vector<uint64_t> expected;
            if (r.kind==Checkpoint || r.kind==End)
            {
                const auto count=probe(*xp,*lsp,gate).words.size();
                if (r.value!=count*8) fail("State checkpoint size mismatch");
                expected.resize(count);
                input.read(reinterpret_cast<char*>(expected.data()), r.value);
                if (!input) fail("Truncated state checkpoint");
                check=crc32(expected.data(),r.value,check);
            }
            if (check!=r.crc) fail("Trace record CRC mismatch");
            if (!resetSeen && r.kind!=Reset) fail("RESET must be first");
            if (resetSeen && !initialCheckpoint && r.kind!=Checkpoint) fail("Initial state checkpoint missing");
            if (checkpointDue && r.kind!=Checkpoint) fail("Scheduled state checkpoint missing");
            if (r.kind==Checkpoint && initialCheckpoint && !checkpointDue) fail("Unscheduled/duplicate checkpoint");
            if (frameIndex==header.bootFrames+header.caseFrames && r.kind!=End && !checkpointDue) fail("Expected END after final FRAME");
            ++records;
            switch (r.kind)
            {
            case Reset:
                if (resetSeen || records!=1 || r.chip || r.address || r.value) fail("Invalid/missing cold RESET");
                xp->reset(); lsp->clear(); gate=false; resetSeen=true;
                break;
            case Write:
            case Read:
            {
                if ((r.chip!=1 && r.chip!=2) || r.value>255) fail("Invalid byte access");
                if (r.kind==Write)
                {
                    if (r.chip==1) xp->hostWrite8(r.address,static_cast<uint8_t>(r.value));
                    else lsp->hostWrite(r.address,static_cast<uint8_t>(r.value));
                    ++writes;
                }
                else
                {
                    const auto value=r.chip==1 ? xp->hostRead8(r.address) : lsp->hostRead(r.address);
                    if (value!=r.value) fail("Read result mismatch: reference="+std::to_string(r.value)+" actual="+std::to_string(value));
                    ++reads;
                }
                break;
            }
            case Gate:
                if (r.chip || r.address!=0xfe86 || r.value>255) fail("Invalid P3 return gate");
                gate=(r.value&128)!=0; ++gateWrites;
                break;
            case Irq:
            {
                if (r.chip!=1 || r.address!=0xfe8f) fail("Invalid IRQ port read");
                const uint8_t value=xp->interruptState() ? 0xfd : 0xff;
                if (value!=r.value) fail("IRQ read result mismatch");
                ++irqReads;
                break;
            }
            case Frame:
            {
                if (r.chip || r.address || r.value || frameIndex>=header.bootFrames+header.caseFrames) fail("Invalid FRAME boundary");
                xp->step();
                auto& dsp=xp->dsp();
                const auto& busB=dsp.serialOutput(xpLib::Dsp::SerialBus::b);
                const auto& busC=dsp.serialOutput(xpLib::Dsp::SerialBus::c);
                const auto count=dsp.serialOutputCount(xpLib::Dsp::SerialBus::b);
                const int32_t values[2]={dsp.serialOutputCount(xpLib::Dsp::SerialBus::c)>=2 ? busC[0] : 0, dsp.serialOutputCount(xpLib::Dsp::SerialBus::c)>=2 ? busC[1] : 0};
                const lspLib::LSPDispatcher::SampleFrame send{count>0 ? busB[0] : 0, count>1 ? busB[1] : 0};
                if (lsp->running() && lsp->hasProgram()) ++lspActive;
                if (send.first || send.second) ++lspInput;
                const auto result=lsp->process(send);
                std::array<int32_t,2> returns{};
                if (gate) returns={result.first>>8,result.second>>8};
                if (returns[0] || returns[1]) ++nonzeroReturns;
                dsp.setSerialInput(xpLib::Dsp::SerialBus::a,returns.data(),returns.size());
                (frameIndex<header.bootFrames ? boot : pcm).write(reinterpret_cast<const char*>(values),sizeof(values));
                ++frameIndex; sequence=0;
                checkpointDue=frameIndex%header.interval==0;
                break;
            }
            case Checkpoint:
            case End:
            {
                if (r.chip || r.address) fail("Invalid checkpoint target");
                const auto state=probe(*xp,*lsp,gate);
                if (expected!=state.words)
                {
                    auto named=probe(*xp,*lsp,gate,true);
                    for (size_t i=0; i<expected.size(); ++i)
                        if (expected[i]!=state.words[i])
                        {
                            std::ostringstream reason;
                            reason << "State mismatch field=" << named.labels[i] << " reference=" << expected[i] << " actual=" << state.words[i] << " reference_hex=0x" << std::hex << expected[i] << " actual_hex=0x" << state.words[i];
                            fail(reason.str());
                        }
                }
                ++checkpoints;
                initialCheckpoint=true;
                checkpointDue=false;
                if (r.kind==End)
                {
                    if (frameIndex!=header.bootFrames+header.caseFrames) fail("Early END");
                    endSeen=true;
                }
                break;
            }
            default: fail("Unknown Trace event kind");
            }
        }
        if (input.peek()!=std::char_traits<char>::eof()) throw std::runtime_error("Trailing Trace records after END");
        boot.close(); pcm.close();
        std::ofstream report(out/"replay.json");
        report.exceptions(std::ios::badbit|std::ios::failbit);
        report << "{\"success\":true,\"cpu_instructions\":0,\"control_rom_loaded\":false,\"frames\":" << frameIndex << ",\"records\":" << records << ",\"reads\":" << reads << ",\"writes\":" << writes << ",\"irq_reads\":" << irqReads << ",\"gate_writes\":" << gateWrites << ",\"state_checkpoints\":" << checkpoints << ",\"lsp_active_frames\":" << lspActive << ",\"lsp_input_frames\":" << lspInput << ",\"lsp_return_frames\":" << nonzeroReturns << "}\n";
        std::cout << "SC88_REPLAY_COMPLETE frames=" << frameIndex << " state_checkpoints=" << checkpoints << '\n';
        return 0;
    }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
