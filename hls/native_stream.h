// SPDX-License-Identifier: GPL-3.0-only
#pragma once
// Software-only FIFO used by the MSVC reference integration, never by synthesis or RTL co-sim.
#include <deque>
#include <stdexcept>
namespace hls {
template<class T> class stream {
    std::deque<T> values;
public:
    void write(T value) { values.push_back(value); }
    T read() { if (values.empty()) throw std::runtime_error("Missing ROM response"); T value=values.front(); values.pop_front(); return value; }
    bool empty() const { return values.empty(); }
};
}
