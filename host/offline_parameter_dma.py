"""PS-normalized frame records for the shared parameter/wave DDR reader."""
import json
from pathlib import Path
import struct

from offline_parameter_format import STAGE_MASKS

ROOT = Path(__file__).resolve().parents[1]
HEADER = struct.Struct("<8sQIIHHI")
MAGIC = b"SC88DMA1"
MAX_BYTES = 16384
STATE = json.loads((ROOT / "reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))
WIDTHS = {f["word"]: f["width"] for f in STATE["state_fields"]}


def packet_check(voice, stage, mask, terminal, values):
    if not 0 <= voice < 64 or stage not in STAGE_MASKS or mask & ~STAGE_MASKS[stage]:
        raise ValueError("Packet identity or stage mask")
    if not -1 <= terminal <= 4 or terminal != -1 and stage != 4 or not mask and terminal == -1:
        raise ValueError("Terminal candidate or empty packet")
    if len(values) != 22:
        raise ValueError("Packet lane count")
    for i, value in enumerate(values):
        width = 1 if i == 21 else 20 if i >= 15 else 18
        if value < 0 or value >= 1 << width or 6 <= i <= 10 and value & 0x20000 or not mask >> i & 1 and value:
            raise ValueError("PC field width, hold or absent lane")


def encode(frame, configs, packets):
    if not 0 <= frame < 1 << 64:
        raise ValueError("Frame number")
    words = []
    for voice, word, value in configs:
        if not 0 <= voice < 64 or word not in WIDTHS or not 0 <= value < 1 << WIDTHS[word]:
            raise ValueError("Host configuration word")
        words.append(1 << 60 | voice << 54 | word << 48 | value)
    previous = (-1, -1)
    for voice, stage, mask, terminal, values in packets:
        packet_check(voice, stage, mask, terminal, values)
        if (voice, stage) <= previous:
            raise ValueError("Duplicate or unordered hook")
        previous = voice, stage
        words.append(2 << 60 | voice << 54 | stage << 51 | (terminal != -1) << 50 | max(0, terminal) << 47 | mask << 25)
        selected = [value for i, value in enumerate(values) if mask >> i & 1]
        for i in range(0, len(selected), 2):
            words.append(selected[i] | (selected[i+1] << 32 if i+1 < len(selected) else 0))
    size = (32 + len(words)*8 + 31) & ~31
    if size > MAX_BYTES:
        raise ValueError("Normalized frame exceeds buffer")
    return HEADER.pack(MAGIC, frame, size, len(words), len(configs), len(packets), 0) + struct.pack(f"<{len(words)}Q", *words) + bytes(size-32-len(words)*8)


def decode(data, expected_frame=None):
    if len(data) < 32:
        raise ValueError("Truncated frame")
    magic, frame, size, count, configs_count, packets_count, flags = HEADER.unpack_from(data)
    if magic != MAGIC or flags or size != len(data) or size > MAX_BYTES or size % 32 or count*8+32 > size or (count*8+63)&~31 != size:
        raise ValueError("DMA frame header")
    if expected_frame is not None and frame != expected_frame:
        raise ValueError("DMA frame identity")
    if any(data[32+count*8:]):
        raise ValueError("Alignment padding")
    words = struct.unpack_from(f"<{count}Q", data, 32)
    configs, packets = [], []
    cursor = 0
    for _ in range(configs_count):
        if cursor >= count:
            raise ValueError("Missing configuration")
        word = words[cursor]; cursor += 1
        voice, address, value = word >> 54 & 63, word >> 48 & 63, word & 0xffffffff
        if word >> 60 != 1 or word >> 32 & 0xffff or address not in WIDTHS or value >= 1 << WIDTHS[address]:
            raise ValueError("Configuration opcode, word or width")
        configs.append((voice, address, value))
    previous = (-1, -1)
    for _ in range(packets_count):
        if cursor >= count:
            raise ValueError("Missing packet")
        header = words[cursor]; cursor += 1
        voice, stage = header >> 54 & 63, header >> 51 & 7
        terminal, reason = bool(header >> 50 & 1), header >> 47 & 7
        mask = header >> 25 & ((1 << 22)-1)
        if header >> 60 != 2 or header & ((1 << 25)-1) or not terminal and reason:
            raise ValueError("Packet header")
        lanes = (mask.bit_count()+1)//2
        if cursor+lanes > count:
            raise ValueError("Missing values")
        selected = [words[cursor+i//2] >> (32*(i%2)) & 0xffffffff for i in range(mask.bit_count())]
        if mask.bit_count()%2 and words[cursor+lanes-1] >> 32:
            raise ValueError("Odd value padding")
        cursor += lanes
        values = [0]*22
        incoming = iter(selected)
        for i in range(22):
            if mask >> i & 1:
                values[i] = next(incoming)
        packet_check(voice, stage, mask, reason if terminal else -1, values)
        if (voice, stage) <= previous:
            raise ValueError("Duplicate or unordered hook")
        previous = voice, stage
        packets.append((voice, stage, mask, reason if terminal else -1, values))
    if cursor != count:
        raise ValueError("Unused payload words or incorrect counts")
    return frame, configs, packets
