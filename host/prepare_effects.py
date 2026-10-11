"""Prepare the pinned interpreter for Cortex-A9's threadless C++ runtime."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def prepare():
    source = ROOT / "external/gearmulator/source/ronaldo/custom_chips"
    target = ROOT / "build/effects-overlay/custom_chips"
    for folder in ("xp", "lsp"):
        (target / folder).mkdir(parents=True, exist_ok=True)
        for path in (source / folder).iterdir():
            if path.suffix in (".h", ".cpp"):
                shutil.copyfile(path, target / folder / path.name)
    shutil.copyfile(source / "jitHost.h", target / "jitHost.h")
    shutil.copyfile(source / "pcmInterpolation.h", target / "pcmInterpolation.h")
    # Only the None backend is available on ARMv7; it never schedules compilation.
    (target / "jitCompileWorker.h").write_text('''// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "jitHost.h"
#include <utility>
namespace chips {
enum class JitHostState { Pending, Ready, Failed };
template<class Backend> JitHostState pollHostBackend(Backend&) { return JitHostState::Failed; }
template<JitCompile Mode, class Snapshot, class Result = bool>
class JitCompileWorker {
    static_assert(Mode == JitCompile::None, "Bare-metal interpreter only");
public:
    static constexpr bool Available = false;
    template<class Compile, class Poll> JitCompileWorker(Compile&&, Poll&&) {}
    bool inFlight() const { return false; }
    template<class Fill> void kick(Fill&&) {}
    template<class Fill> bool poll(Fill&&, Result&) { return false; }
};
}
''', encoding="utf-8")
    return target.parent


if __name__ == "__main__":
    print(prepare())
