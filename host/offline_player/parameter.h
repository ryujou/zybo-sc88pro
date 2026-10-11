// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "custom_chips/xp/xp.h"
#include "custom_chips/lsp/lsp.h"
#include <filesystem>
#include <fstream>
#include <functional>
#include <vector>

namespace sc88param
{
using Voice = xpLib::XP::VoiceState;
using Values = std::array<uint32_t, 22>;
Values values(const Voice&);
void setField(Voice&, unsigned, uint32_t);
uint32_t& terminalControl(Voice&, uint8_t);
void beginCompute(uint8_t, size_t, Voice&);
void endCompute();
void terminalAttempt(size_t, uint8_t, const std::function<void()>&);
template<class F> void compute(uint8_t stage, size_t voice, Voice& state, F&& calculation)
{
    beginCompute(stage, voice, state);
    calculation();
    endCompute();
}
template<class F> void attempt(size_t voice, uint8_t reason, F&& arbitration)
{
    terminalAttempt(voice, reason, std::forward<F>(arbitration));
}
void consume(uint8_t, size_t, Voice&, const std::function<void(uint8_t)>&);

enum Kind : uint8_t { Reset=1, Write=2, Read=3, Gate=4, Frame=5, Delta=6, Terminal=7, End=8 };
struct Header
{
    uint64_t bootFrames=0, caseFrames=0, tailFrames=0;
    std::string commit;
};
struct Event
{
    uint64_t frame=0;
    uint32_t sequence=0;
    uint8_t kind=0, stage=0, target=0, voice=255;
    uint32_t mask=0;
    std::vector<uint8_t> payload;
};

class Writer
{
public:
    Writer(const std::filesystem::path&, uint64_t, uint64_t, const std::string&, uint64_t tail=0);
    void reset(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void frame(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void finish(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void record(uint8_t, uint8_t stage=0, uint8_t target=0, uint8_t voice=255, uint32_t mask=0, const std::vector<uint8_t>& payload={});
    void assertion(uint8_t, uint8_t, uint16_t, uint32_t);
    bool started=false;
    uint64_t frameIndex=0;
private:
    void checkpoint(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void flushBlock();
    std::ofstream output, assertions;
    Header header;
    std::vector<uint8_t> block;
    uint64_t blockFirstFrame=0, blockLastFrame=0;
    uint32_t sequence=0, blockRecords=0, blockIndex=0;
    bool complete=false;
    std::filesystem::path path;
    uint32_t segmentIndex=0;
    uint64_t segmentBytes=104;
};
class Reader
{
public:
    Reader(const std::filesystem::path&, const std::string&);
    const Event& peek();
    Event take();
    void nextFrame();
    void finish();
    Header header;
    uint64_t frameIndex=0, records=0;
    uint64_t logicalBlocks=0, largestBlockBytes=0, peakBufferCapacity=0;
private:
    void readEvent();
    std::ifstream input;
    std::vector<uint8_t> block;
    size_t position=0;
    uint32_t sequence=0, remaining=0, blockIndex=0;
    uint64_t blockLastFrame=0;
    bool pending=false;
    Event event;
    std::filesystem::path path;
    uint32_t segmentIndex=0;
    std::array<uint8_t, 256> controlSeen{};
};
extern Writer* active;
extern Reader* replay;
void access(bool, uint8_t, uint16_t, uint8_t);
void irqRead(bool);
void returnGate(uint8_t);
void reset(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
void frame(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
}
