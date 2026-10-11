// SPDX-License-Identifier: GPL-3.0-only
#include "parameter.h"
#include "trace.h"
#include <cstring>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace sc88param
{
Writer* active=nullptr;
Reader* replay=nullptr;
namespace
{
constexpr uint32_t fieldMask=(1u<<22)-1, maxBlockBytes=8u*1024*1024;
Voice* computing=nullptr;
Values baseline{};
uint8_t computingStage=0, computingVoice=0;

void put(std::vector<uint8_t>& b, uint64_t value, unsigned bytes)
{
    for (unsigned i=0; i<bytes; ++i) b.push_back(static_cast<uint8_t>(value>>(i*8)));
}
uint64_t get(const std::vector<uint8_t>& b, size_t& p, unsigned bytes)
{
    if (p+bytes>b.size()) throw std::runtime_error("Truncated parameter field");
    uint64_t value=0;
    for (unsigned i=0; i<bytes; ++i) value|=uint64_t{b[p++]}<<(i*8);
    return value;
}
void write(std::ofstream& s, const std::vector<uint8_t>& b)
{
    s.write(reinterpret_cast<const char*>(b.data()), b.size());
}
std::vector<uint8_t> read(std::ifstream& s, size_t bytes)
{
    std::vector<uint8_t> b(bytes);
    s.read(reinterpret_cast<char*>(b.data()), bytes);
    if (!s) throw std::runtime_error("Truncated parameter header/block or missing END");
    return b;
}
std::filesystem::path segmentPath(const std::filesystem::path& path, uint32_t index)
{
    if (!index) return path;
    std::ostringstream suffix;
    suffix << '.' << std::setfill('0') << std::setw(3) << index;
    return path.parent_path()/(path.stem().string()+suffix.str()+path.extension().string());
}
std::vector<uint8_t> encodeHeader(const Header& h, uint32_t segment, uint32_t firstBlock)
{
    std::vector<uint8_t> b{'S','C','8','8','P','A','R','1'};
    put(b,1,4); put(b,32000,4); put(b,h.bootFrames,8); put(b,h.caseFrames,8);
    put(b,h.tailFrames,8); put(b,h.bootFrames+h.caseFrames,8);
    b.insert(b.end(), h.commit.begin(),h.commit.end());
    put(b,1,4); put(b,1,4); put(b,segment,4); put(b,firstBlock,4);
    return b;
}
Header decodeHeader(const std::vector<uint8_t>& b, const std::string& commit, uint32_t segment, uint32_t firstBlock)
{
    if (std::memcmp(b.data(),"SC88PAR1",8)) throw std::runtime_error("Parameter magic mismatch");
    size_t p=8;
    if (get(b,p,4)!=1 || get(b,p,4)!=32000) throw std::runtime_error("Parameter version/rate mismatch");
    Header h;
    h.bootFrames=get(b,p,8); h.caseFrames=get(b,p,8); h.tailFrames=get(b,p,8);
    const auto total=get(b,p,8);
    h.commit=std::string(reinterpret_cast<const char*>(b.data()+p),40); p+=40;
    if (h.commit!=commit || !h.bootFrames || !h.caseFrames || h.tailFrames>h.caseFrames ||
        total<h.bootFrames || total!=h.bootFrames+h.caseFrames || get(b,p,4)!=1 || get(b,p,4)!=1 ||
        get(b,p,4)!=segment || get(b,p,4)!=firstBlock)
        throw std::runtime_error("Parameter identity/duration/segment mismatch");
    return h;
}
void validate(const Event& e)
{
    if (e.kind==Delta || e.kind==Terminal)
    {
        if (e.target!=1 || e.voice>=64 || e.stage<1 || e.stage>4) throw std::runtime_error("Illegal control consumption position");
        if (e.kind==Terminal && (e.stage!=4 || e.mask || e.payload.size()!=1 || e.payload[0]>4)) throw std::runtime_error("Illegal terminal candidate");
        if (e.kind==Delta)
        {
            const uint32_t allowed[]={0,(1u<<0)|(1u<<11)|(1u<<12)|(1u<<14)|(1u<<16),1u<<12,(1u<<0)|(1u<<16),fieldMask&~(0xfu<<6)};
            if (!e.mask || (e.mask&~allowed[e.stage]) || e.payload.size()!=std::popcount(e.mask)*4u) throw std::runtime_error("Illegal control mask/payload width/stage");
            size_t p=0;
            for (unsigned i=0; i<22; ++i) if (e.mask&(1u<<i))
            {
                const auto v=get(e.payload,p,4);
                const auto width=i==21 ? 1u : i>=15 ? 20u : 18u;
                if (v>=(1u<<width) || (i>=6 && i<=10 && (v&0x20000))) throw std::runtime_error("Illegal control field width/local hold injection");
            }
        }
        return;
    }
    if (e.stage || e.voice!=255 || e.mask) throw std::runtime_error("Illegal host/frame event fields");
    switch(e.kind)
    {
    case Reset: case Frame: case End:
        if (e.target || !e.payload.empty()) throw std::runtime_error("Illegal boundary event payload"); break;
    case Write:
        if ((e.target!=1 && e.target!=2) || e.payload.size()!=3) throw std::runtime_error("Illegal host write"); break;
    case Read:
        if (e.target>2 || e.payload.size()!=2) throw std::runtime_error("Illegal host read");
        if (!e.target && (e.payload[0]!=0x8f || e.payload[1]!=0xfe)) throw std::runtime_error("Illegal IRQ port query"); break;
    case Gate:
        if (e.target || e.payload.size()!=1) throw std::runtime_error("Illegal return gate"); break;
    default: throw std::runtime_error("Unknown parameter event; audio post-state is not permitted");
    }
}
void flushControls()
{
    if (!computing || !active || !active->started) return;
    const auto now=values(*computing);
    uint32_t mask=0;
    std::vector<uint8_t> payload;
    for (unsigned i=0; i<now.size(); ++i) if (now[i]!=baseline[i])
    {
        mask|=1u<<i; put(payload,now[i],4);
    }
    if (mask) active->record(Delta,computingStage,1,computingVoice,mask,payload);
    baseline=now;
}
}

Values values(const Voice& v)
{
    return {v.pitchIncrement_0d00,v.tvfQDestination_1100,v.pitchDestination_1200,v.tvfFDestination_1300,v.ampModDestination_1400,v.ampDestination_1500,
        v.tvfQRamp_1600&~0x20000u,v.pitchRamp_1700&~0x20000u,v.tvfFRamp_1800&~0x20000u,v.ampModRamp_1900&~0x20000u,v.ampRamp_1a00&~0x20000u,
        v.pitchCurrent_1b00,v.tvfFCurrent_1c00,v.ampModCurrent_1d00,v.ampCurrent_1e00,v.tvfQCurrent_2100,v.tvfFCoefficient_2200,v.combinedAmp_2300,
        v.pitchStep_2400,v.tvfFStep_2500,v.ampStep_2600,static_cast<uint32_t>(v.runtimeCache.ampCurve2EntryPending)};
}
void setField(Voice& v, unsigned i, uint32_t value)
{
    uint32_t* fields[]={&v.pitchIncrement_0d00,&v.tvfQDestination_1100,&v.pitchDestination_1200,&v.tvfFDestination_1300,&v.ampModDestination_1400,&v.ampDestination_1500,
        &v.tvfQRamp_1600,&v.pitchRamp_1700,&v.tvfFRamp_1800,&v.ampModRamp_1900,&v.ampRamp_1a00,
        &v.pitchCurrent_1b00,&v.tvfFCurrent_1c00,&v.ampModCurrent_1d00,&v.ampCurrent_1e00,&v.tvfQCurrent_2100,&v.tvfFCoefficient_2200,&v.combinedAmp_2300,
        &v.pitchStep_2400,&v.tvfFStep_2500,&v.ampStep_2600};
    if (i==21) v.runtimeCache.ampCurve2EntryPending=value!=0;
    else if (i>=6 && i<=10) *fields[i]=(*fields[i]&0x20000u)|value;
    else *fields[i]=value;
}
uint32_t& terminalControl(Voice& v, uint8_t reason)
{
    uint32_t* controls[]={&v.tvfQRamp_1600,&v.tvfFRamp_1800,&v.pitchRamp_1700,&v.ampModRamp_1900,&v.ampRamp_1a00};
    if (reason>4) throw std::runtime_error("Invalid terminal reason");
    return *controls[reason];
}
void beginCompute(uint8_t stage, size_t voice, Voice& state)
{
    computing=&state; baseline=values(state); computingStage=stage; computingVoice=static_cast<uint8_t>(voice);
}
void endCompute() { flushControls(); computing=nullptr; }
void terminalAttempt(size_t voice, uint8_t reason, const std::function<void()>& arbitration)
{
    flushControls();
    if (active && active->started) active->record(Terminal,computingStage,1,static_cast<uint8_t>(voice),0,{reason});
    arbitration();
    if (computing) baseline=values(*computing);
}
void consume(uint8_t stage, size_t voice, Voice& state, const std::function<void(uint8_t)>& arbitration)
{
    if (!replay) throw std::runtime_error("Parameter consumer has no stream");
    bool deltaSeen=false, terminalSeen=false;
    for (;;)
    {
        const auto& next=replay->peek();
        if (next.frame!=replay->frameIndex || next.stage!=stage || next.voice!=voice || (next.kind!=Delta && next.kind!=Terminal)) return;
        const auto event=replay->take();
        if (event.kind==Terminal)
        {
            if (terminalSeen) throw std::runtime_error("Duplicate terminal candidate");
            terminalSeen=true; arbitration(event.payload[0]);
        }
        else
        {
            if (deltaSeen || terminalSeen) throw std::runtime_error("Duplicate/reordered control delta");
            deltaSeen=true;
            size_t p=0;
            for (unsigned i=0; i<22; ++i) if (event.mask&(1u<<i)) setField(state,i,static_cast<uint32_t>(get(event.payload,p,4)));
        }
    }
}

Writer::Writer(const std::filesystem::path& destination, uint64_t boot, uint64_t frames, const std::string& commit, uint64_t tail)
    : output(destination,std::ios::binary), assertions(destination.parent_path()/"assertions.bin",std::ios::binary), path(destination)
{
    if (commit.size()!=40 || !boot || !frames || tail>frames) throw std::runtime_error("Invalid parameter export duration/identity");
    output.exceptions(std::ios::badbit|std::ios::failbit); assertions.exceptions(std::ios::badbit|std::ios::failbit);
    header={boot,frames,tail,commit};
    write(output,encodeHeader(header,0,0));
    assertions.write("SC88AST1",8);
}
void Writer::record(uint8_t kind, uint8_t stage, uint8_t target, uint8_t voice, uint32_t mask, const std::vector<uint8_t>& payload)
{
    if (!started || complete) return;
    Event e{frameIndex,sequence++,kind,stage,target,voice,mask,payload}; validate(e);
    if (!blockRecords) blockFirstFrame=frameIndex;
    blockLastFrame=frameIndex;
    put(block,e.frame,8); put(block,e.sequence,4); put(block,e.kind,1); put(block,e.stage,1);
    put(block,e.target,1); put(block,e.voice,1); put(block,e.mask,4); put(block,e.payload.size(),4);
    block.insert(block.end(),payload.begin(),payload.end()); ++blockRecords;
    if (block.size()>maxBlockBytes) throw std::runtime_error("Parameter logical block exceeds 8 MiB");
}
void Writer::flushBlock()
{
    if (!blockRecords) return;
    if (segmentBytes+32+block.size()>0xffffffffull)
    {
        output.close(); ++segmentIndex;
        output.open(segmentPath(path,segmentIndex),std::ios::binary);
        write(output,encodeHeader(header,segmentIndex,blockIndex)); segmentBytes=104;
    }
    std::vector<uint8_t> b{'P','B','L','1'};
    put(b,blockIndex++,4); put(b,blockFirstFrame,8); put(b,blockLastFrame,8);
    put(b,block.size(),4); put(b,blockRecords,4); write(output,b); write(output,block);
    segmentBytes+=b.size()+block.size(); block.clear(); blockRecords=0;
}
void Writer::assertion(uint8_t kind, uint8_t target, uint16_t address, uint32_t value)
{
    if (!started || complete) return;
    std::vector<uint8_t> b;
    put(b,frameIndex,8); put(b,sequence-1,4); put(b,kind,1); put(b,target,1); put(b,address,2); put(b,value,4); put(b,0,4); write(assertions,b);
}
void Writer::checkpoint(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    const auto state=sc88trace::probe(xp,lsp,gate);
    std::vector<uint8_t> b;
    put(b,frameIndex,8); put(b,0,4); put(b,10,1); put(b,0,1); put(b,0,2); put(b,0,4); put(b,state.words.size()*8,4);
    write(assertions,b);
    assertions.write(reinterpret_cast<const char*>(state.words.data()),state.words.size()*8);
}
void Writer::reset(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (started) throw std::runtime_error("Unexpected second cold reset");
    started=true; record(Reset); checkpoint(xp,lsp,gate);
}
void Writer::frame(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (!started) return;
    record(Frame); ++frameIndex; sequence=0;
    if (frameIndex%256==0) flushBlock();
    if (frameIndex%32768==0) checkpoint(xp,lsp,gate);
}
void Writer::finish(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate)
{
    if (!started || frameIndex!=header.bootFrames+header.caseFrames) throw std::runtime_error("Incomplete parameter export");
    record(End); checkpoint(xp,lsp,gate); flushBlock(); complete=true; output.close(); assertions.close();
}

Reader::Reader(const std::filesystem::path& source, const std::string& commit) : input(source,std::ios::binary), path(source)
{
    if (!input) throw std::runtime_error("Cannot open parameter stream");
    header=decodeHeader(read(input,104),commit,0,0);
}
void Reader::readEvent()
{
    if (pending) return;
    if (!remaining)
    {
        if (position!=block.size()) throw std::runtime_error("Logical block record count mismatch");
        if (sequence) throw std::runtime_error("Logical block split inside an audio frame");
        if (input.peek()==std::char_traits<char>::eof())
        {
            input.close(); ++segmentIndex; input.open(segmentPath(path,segmentIndex),std::ios::binary);
            if (!input) throw std::runtime_error("Missing parameter segment / END");
            const auto next=decodeHeader(read(input,104),header.commit,segmentIndex,blockIndex);
            if (next.bootFrames!=header.bootFrames || next.caseFrames!=header.caseFrames || next.tailFrames!=header.tailFrames) throw std::runtime_error("Segment duration mismatch");
        }
        const auto b=read(input,32); size_t p=4;
        if (std::memcmp(b.data(),"PBL1",4) || get(b,p,4)!=blockIndex++) throw std::runtime_error("Logical block magic/order mismatch");
        const auto first=get(b,p,8); blockLastFrame=get(b,p,8); const auto bytes=get(b,p,4); remaining=static_cast<uint32_t>(get(b,p,4));
        if (first!=frameIndex || blockLastFrame<first || blockLastFrame>header.bootFrames+header.caseFrames || !bytes || bytes>maxBlockBytes || !remaining || remaining>bytes/24) throw std::runtime_error("Logical block frame range/length mismatch");
        auto nextBlock=read(input,static_cast<size_t>(bytes));
        peakBufferCapacity=std::max<uint64_t>(peakBufferCapacity,block.capacity()+nextBlock.capacity()+event.payload.capacity());
        block=std::move(nextBlock); position=0;
        ++logicalBlocks; largestBlockBytes=std::max(largestBlockBytes,bytes+32);
    }
    event.frame=get(block,position,8); event.sequence=static_cast<uint32_t>(get(block,position,4));
    event.kind=static_cast<uint8_t>(get(block,position,1)); event.stage=static_cast<uint8_t>(get(block,position,1));
    event.target=static_cast<uint8_t>(get(block,position,1)); event.voice=static_cast<uint8_t>(get(block,position,1));
    event.mask=static_cast<uint32_t>(get(block,position,4)); const auto bytes=get(block,position,4);
    if (bytes>block.size()-position) throw std::runtime_error("Truncated event payload");
    event.payload.assign(block.begin()+position,block.begin()+position+bytes); position+=bytes; --remaining;
    if (event.frame!=frameIndex || event.sequence!=sequence || event.frame>blockLastFrame || (!remaining && event.frame!=blockLastFrame)) throw std::runtime_error("Parameter frame/sequence/block endpoint mismatch");
    validate(event);
    if(event.kind==Delta || event.kind==Terminal)
    {
        auto& seen=controlSeen[event.voice*4+event.stage-1];
        if((event.kind==Delta && seen) || (event.kind==Terminal && (seen&2))) throw std::runtime_error("Duplicate/reordered control service event");
        seen|=event.kind==Delta ? 1 : 2;
    }
    peakBufferCapacity=std::max<uint64_t>(peakBufferCapacity,block.capacity()+event.payload.capacity());
    pending=true;
}
const Event& Reader::peek() { readEvent(); return event; }
Event Reader::take() { readEvent(); pending=false; ++sequence; ++records; return event; }
void Reader::nextFrame() { ++frameIndex; sequence=0; controlSeen.fill(0); }
void Reader::finish()
{
    if (pending || remaining || position!=block.size() || input.peek()!=std::char_traits<char>::eof()) throw std::runtime_error("Trailing parameter records/bytes");
    if (std::filesystem::exists(segmentPath(path,segmentIndex+1))) throw std::runtime_error("Trailing parameter segment after END");
}

void access(bool isWrite, uint8_t target, uint16_t address, uint8_t value)
{
    if (!active || !active->started) return;
    std::vector<uint8_t> payload; put(payload,address,2); if(isWrite) put(payload,value,1);
    active->record(isWrite ? Write : Read,0,target,255,0,payload);
    if (!isWrite) active->assertion(Read,target,address,value);
}
void irqRead(bool pending)
{
    if (!active || !active->started) return;
    active->record(Read,0,0,255,0,{0x8f,0xfe}); active->assertion(Read,0,0xfe8f,pending ? 0xfd : 0xff);
}
void returnGate(uint8_t value) { if (active) active->record(Gate,0,0,255,0,{value}); }
void reset(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate) { if (active) active->reset(xp,lsp,gate); }
void frame(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate) { if (active) active->frame(xp,lsp,gate); }
}
