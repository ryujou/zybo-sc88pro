// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "custom_chips/xp/xp.h"
#include "custom_chips/lsp/lsp.h"
#include <bit>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace sc88trace
{
static_assert(std::endian::native == std::endian::little);
enum Kind : uint8_t { Reset=1, Write=2, Read=3, Gate=4, Irq=5, Frame=6, Checkpoint=7, End=8 };
#pragma pack(push, 1)
struct Header
{
    char magic[8];
    uint32_t version, rate;
    uint64_t bootFrames, caseFrames;
    char commit[40];
    uint32_t interval, crc;
};
struct Record
{
    uint64_t frame;
    uint32_t sequence;
    uint8_t kind, chip;
    uint16_t address;
    uint32_t value, crc;
};
#pragma pack(pop)
static_assert(sizeof(Header) == 80 && sizeof(Record) == 24);
uint32_t crc32(const void* bytes, size_t size, uint32_t prior = 0);

struct Probe
{
    std::vector<uint64_t> words;
    std::vector<std::string> labels;
    bool named;
    template<class T> void field(const std::string& name, T value)
    {
        words.push_back(static_cast<uint64_t>(value));
        if (named) labels.push_back(name);
    }
    template<class T> void array(const std::string& name, const T& values)
    {
        size_t index = 0;
        for (auto value : values) field(named ? name + "[" + std::to_string(index++) + "]" : name, value);
    }
};
Probe probe(const xpLib::XP& xp, const lspLib::LSPDispatcher& lsp, bool gate, bool named = false);

class Writer
{
public:
    Writer(const std::filesystem::path& path, uint64_t boot, uint64_t frames, const std::string& commit);
    void reset(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void record(uint8_t kind, uint8_t chip=0, uint16_t address=0, uint32_t value=0, const Probe* state=nullptr);
    void frame(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
    void finish(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
private:
    std::ofstream output;
    Header header{};
    uint64_t frameIndex=0;
    uint32_t sequence=0;
    bool started=false, complete=false;
};
extern Writer* active;
void access(bool write, uint8_t chip, uint16_t address, uint8_t value);
void irqRead(bool pending);
void returnGate(uint8_t value);
void reset(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
void frame(const xpLib::XP&, const lspLib::LSPDispatcher&, bool);
}
