// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "custom_chips/xp/xp.h"
#include "custom_chips/lsp/lsp.h"

class Sc88ParameterEffects
{
public:
    void control(uint64_t word);
    int process(const uint64_t* sends, unsigned count, uint64_t& stereo);

private:
    // XP supplies the byte host register protocol only; voice synthesis stays in PL.
    xpLib::XP host;
    lspLib::LSPDispatcher lsp;
    bool gate = false;
};
