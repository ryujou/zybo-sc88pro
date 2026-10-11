// SPDX-License-Identifier: GPL-3.0-only
#include "88lib/boards/sc88pro.h"
#include "88lib/rom/rom.h"
#include "baseLib/md5.h"
#include "baseLib/os.h"
#include "synthLib/midi/midiFile.h"
#ifdef SC88_TRACE_EXPORT
#include "trace.h"
#endif

#include <bit>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;
static_assert(std::endian::native == std::endian::little);

std::vector<uint8_t> readBytes(const fs::path& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read " + path.string());
    return {std::istreambuf_iterator<char>(input), {}};
}

struct Event
{
    uint64_t frame;
    uint8_t port;
    std::vector<uint8_t> bytes;
};

class ReferenceBoard : public emu88Lib::Sc88Pro
{
public:
    using Sc88Pro::Sc88Pro;

    uint16_t xpWord(uint16_t address)
    {
        const auto high = extRead8(0xc80000u + address);
        const auto low = extRead8(0xc80001u + address);
        return static_cast<uint16_t>((high << 8) | low);
    }

    uint32_t xpLatched(uint16_t address)
    {
        xpWord(address);
        const auto low = xpWord(0x3910);
        const auto high = xpWord(0x3912);
        return (static_cast<uint32_t>(high) << 16) | low;
    }

    void saveSnapshot(const fs::path& path)
    {
        // Readback changes XP host latches; snapshots are taken only after PCM capture ends.
        std::ofstream output(path);
        output.exceptions(std::ios::badbit | std::ios::failbit);
        output << "slot,pram,cram,iram1,iram2\n";
        for (unsigned slot = 0; slot < 256; ++slot)
        {
            const auto pram = xpLatched(static_cast<uint16_t>(0x3402 + slot * 4));
            const auto cram = xpLatched(static_cast<uint16_t>(0x2c00 + slot * 2));
            output << std::dec << slot << ',' << std::hex << pram << ',' << cram << ',';
            if (slot < 64)
                output << xpLatched(static_cast<uint16_t>(0x3002 + slot * 4)) << ','
                       << xpLatched(static_cast<uint16_t>(0x3102 + slot * 4));
            else
                output << ',';
            output << '\n';
        }
    }
};

std::vector<Event> readEvents(const fs::path& path)
{
    std::vector<Event> events;
    if (path.extension() == ".mid")
    {
        std::vector<synthLib::midi::Event> midi;
        std::string error;
        if (!synthLib::midi::readSmf(readBytes(path), midi, error))
            throw std::runtime_error("SMF: " + error);
        for (const auto& event : midi)
            events.push_back({static_cast<uint64_t>(std::llround(event.seconds * emu88Lib::g_sampleRate)), event.port, event.bytes});
    }
    else
    {
        std::ifstream input(path);
        if (!input) throw std::runtime_error("Cannot read events " + path.string());
        std::string line;
        while (std::getline(input, line))
        {
            if (line.empty()) continue;
            std::istringstream row(line);
            Event event{};
            unsigned port, byte;
            if (!(row >> event.frame >> port) || port > 1)
                throw std::runtime_error("Invalid event frame/port");
            event.port = static_cast<uint8_t>(port);
            while (row >> std::hex >> byte)
            {
                if (byte > 255) throw std::runtime_error("Invalid MIDI byte");
                event.bytes.push_back(static_cast<uint8_t>(byte));
            }
            if (!row.eof() || event.bytes.empty()) throw std::runtime_error("Invalid MIDI event");
            events.push_back(std::move(event));
        }
    }
    uint64_t previous = 0;
    for (const auto& event : events)
    {
        if (event.frame < previous) throw std::runtime_error("Events are not frame-ordered");
        previous = event.frame;
    }
    return events;
}

void send(emu88Lib::Sc88Pro& board, const Event& event)
{
    const auto& bytes = event.bytes;
    synthLib::SMidiEvent midi(synthLib::MidiEventSource::Host);
    if (bytes[0] == 0xf0)
    {
        if (bytes.back() != 0xf7) throw std::runtime_error("Unterminated SysEx");
        midi.sysex.assign(bytes.begin(), bytes.end());
    }
    else
    {
        const auto status = bytes[0] & 0xf0;
        const size_t length = status == 0xc0 || status == 0xd0 ? 2 : 3;
        if (status < 0x80 || status >= 0xf0 || bytes.size() != length)
            throw std::runtime_error("Unsupported MIDI event length/status");
        midi.a = bytes[0];
        midi.b = bytes[1];
        midi.c = length == 3 ? bytes[2] : 0;
    }
    board.addMidiEvent(midi, event.port);
}

void captureFrame(emu88Lib::Sc88Pro& board, std::ofstream& output)
{
    const auto frame = board.renderSample();
    const int32_t values[2] = {frame.first, frame.second};
    for (const auto value : values)
        if (value < -8388608 || value > 8388607)
            throw std::runtime_error("Native output exceeds signed 24-bit range");
    output.write(reinterpret_cast<const char*>(values), sizeof(values));
}

int main(int argc, char** argv)
{
    baseLib::disableErrorDialogs();
    try
    {
        if (argc != 7) throw std::runtime_error("Usage: sc88_reference_runner ROM_DIR EVENTS_OR_MID OUT_DIR BOOT_FRAMES CASE_FRAMES UPSTREAM_COMMIT");
        const fs::path romDir(argv[1]), outDir(argv[3]);
        const uint64_t bootFrames = std::stoull(argv[4]), caseFrames = std::stoull(argv[5]);
        auto firmware = readBytes(romDir / "sc88pro_control.bin");
        if (firmware.size() != emu88Lib::Sc88Pro::RomSize) throw std::runtime_error("Invalid firmware size");
        emu88Lib::normalizeH8WordOrder(firmware);
        if (baseLib::MD5(firmware).toString() != "9d4c2f123b4451d8ee75c3b982760f28") throw std::runtime_error("Firmware is not SC-88Pro 1.02");
        const char* names[] = {"sc88pro_wave0.bin", "sc88pro_wave1.bin", "sc88pro_wave2.bin"};
        const size_t sizes[] = {8388608, 8388608, 4194304};
        const char* hashes[] = {"bd33b20bb5e8f51e436e141f81a75c14", "125ea2056dc208f04a141b3dcdffdb1b", "48c3887c9a2a574b907242640fa0a320"};
        std::vector<uint8_t> waves;
        for (unsigned i = 0; i < 3; ++i)
        {
            const auto data = readBytes(romDir / names[i]);
            if (data.size() != sizes[i] || baseLib::MD5(data).toString() != hashes[i]) throw std::runtime_error("Wave ROM does not match Registry");
            waves.insert(waves.end(), data.begin(), data.end());
        }
        auto events = readEvents(argv[2]);
        if (!events.empty() && events.back().frame >= caseFrames) throw std::runtime_error("Event exceeds case duration");
        fs::create_directories(outDir);
#ifdef SC88_TRACE_EXPORT
        sc88trace::Writer trace(outDir / "register.trace", bootFrames, caseFrames, argv[6]);
        sc88trace::active = &trace;
#endif
        auto board = std::make_unique<ReferenceBoard>(std::move(firmware), waves, true);
        if (!board->isValid() || board->usesSerialMidi()) throw std::runtime_error("Invalid SC-88Pro board/mailbox");
        fs::create_directories(outDir);
        std::ofstream boot(outDir / "boot.pcm", std::ios::binary), pcm(outDir / "native.pcm", std::ios::binary);
        boot.exceptions(std::ios::badbit | std::ios::failbit);
        pcm.exceptions(std::ios::badbit | std::ios::failbit);
        for (uint64_t frame = 0; frame < bootFrames; ++frame) captureFrame(*board, boot);
        const auto bootCycles = board->cycles();
        size_t eventIndex = 0;
        for (uint64_t frame = 0; frame < caseFrames; ++frame)
        {
            while (eventIndex < events.size() && events[eventIndex].frame == frame) send(*board, events[eventIndex++]);
            captureFrame(*board, pcm);
        }
        if (eventIndex != events.size() || board->midiInBacklog() != 0) throw std::runtime_error("MIDI events did not drain");
        boot.close(); pcm.close();
#ifdef SC88_TRACE_EXPORT
        trace.finish(board->traceXp(), board->traceLsp(), board->traceReturnGate());
        sc88trace::active = nullptr;
#endif
        board->saveSnapshot(outDir / "xp-end-state.csv");
        std::ofstream metadata(outDir / "runner.json");
        metadata.exceptions(std::ios::badbit | std::ios::failbit);
        metadata << "{\n  \"sample_rate\": 32000,\n  \"channels\": 2,\n  \"container_bits\": 32,\n  \"valid_bits\": 24,\n  \"boot_frames\": " << bootFrames
                 << ",\n  \"case_frames\": " << caseFrames << ",\n  \"events\": " << eventIndex
                 << ",\n  \"boot_cycles\": " << bootCycles << ",\n  \"end_cycles\": " << board->cycles()
                 << ",\n  \"midi_backlog\": 0,\n  \"factory_reset\": true,\n  \"jit\": false,\n  \"commit\": \"" << argv[6] << "\"\n}\n";
        std::cout << "SC88_REFERENCE_COMPLETE frames=" << caseFrames << " events=" << eventIndex << '\n';
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
