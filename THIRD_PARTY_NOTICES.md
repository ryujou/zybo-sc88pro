# Third-party source notices

## Gearmulator / 88emu

- Authors: The Usual Suspects and the contributors identified in the original source history.
- Source: https://github.com/dsp56300/gearmulator
- Pinned commit: `9af8bb05bcef2994b5dbb60c5c028e978a72aecb`.
- License: GPL-3.0; the full license is retained at `LICENSE.md` and `external/gearmulator/LICENSE.md`.
- Used sources: SC-88Pro board, SC-88 MIDI sub-MCU, ROM normalization/descrambling, XP3/XP DSP, LSP interpreter, H8/500 emulator, HD44780, MIDI parser/SMF reader, and the required baseLib files. Original copyright and source headers are retained unchanged.
- Integration: the project compiles the pinned sources in place and links them into `sc88_reference_runner`. `CHIPS_FORCE_NO_JIT=1` selects upstream interpreter backends. The filesystem source is compiled as C++17, matching its original baseLib build; CPU/LSP and the runner use C++20. No source patch is applied to the Phase 0 reference.
- Phase 1: `host/prepare_trace.py` generates an observation overlay of the SC-88Pro board under `build/trace-overlay` for `sc88_register_trace`. It adds byte-access, IRQ-port-read, P3-return-gate, final factory power-cycle and frame-completion observations, plus XP/LSP accessors. Original source headers are retained; numerical code, H8 scheduling, and the pinned worktree are unchanged. The generated derivative and generator are subject to the applicable GPL obligations. `sc88_trace_replay` links the upstream XP/LSP and descrambler without board/H8 code and without loading Control ROM.
- Offline parameter Phase 1: `host/prepare_offline_player.py` generates GPL-3.0-only derivatives under `build/offline-player-overlay`. `sc88_parameter_export` observes calculated control changes at the pinned launch, post-source refresh and Ramp service positions; its control calculations and CPU scheduling retain the reference expressions. `sc88_parameter_replay` links the calculation-free XP derivative, original audio arithmetic, XP DSP/LSP and descrambler, without board/H8/Control ROM. Local Mute/Loop/terminal arbitration and audio histories advance independently. Computed deltas exclude the local hold bit; optional read/state assertions are separate from executable parameters. The generators, parameter codec, boundary fixtures and corresponding generated source are covered by the applicable GPL source obligations. Parameter files, assertion snapshots, ROM and PCM remain private.
- Phase 2 Gate A: `host/prepare_voice_probe.py` generates observation-only XP source/filter/TVA and ROM-read hooks, including before-source and before-Ramp source-exit snapshots plus a replay observer under `build/voice-overlay`. `host/voice_reference` builds the pinned XP numerical routines with these hooks to emit synthetic Voice goldens and the real Trace's Voice states, stage values and sample fetches. Original comments and source headers remain; no numerical expression, host semantics or pinned source file is changed. The replay probe also exports the existing pinned descrambler output for an independent address-indexed RTL ROM responder. All private ROM-derived vectors stay under `build/`; the observer and corresponding generator are GPL-3.0-only. These programs are reference probes, not an HLS core.
- Phase 2 handwritten RTL: `hardware/rtl` implements fixed XP numeric semantics under GPL-3.0-only. `xp3_interpolation.mem` contains the 384 fixed coefficients from `pcmInterpolation.h` (acknowledgements to InfoSecDJ and NukeYKT); the component test checks every value against the pinned C++ export. The pitch mantissa table is exported by the pinned C++ decodePitch helper. `ramp_vectors.cpp`, `control_vectors.cpp`, `ramp_service_vectors.cpp` and `source_control_vectors.cpp` execute the pinned helpers/XP steps to generate component test inputs and expected values. Handwritten RTL does not depend on HLS generated hardware. Component stimuli and private Trace observations remain under `build/`.

- Offline parameter Phase 2: `xp3_parameter_voice.sv` reuses the GPL sample/filter/pair/state units and consumes the PC control deltas at the fixed hooks, retaining local IRQ/hold arbitration. `prepare_parameter_voice_probe.py`, `parameter_voice_probe.h` and `parameter_irq_vectors.cpp` create observation-only derivatives of the pinned XP and boundary fixtures; their output is compared with the original reference and SC88PAR1 exporter. These derivatives and their handwritten RTL/testbench adaptations are covered by the applicable GPL source obligations. Parameter packets, ROM images, golden state and PCM remain private under `build/`.
- Offline parameter Phase 3: `pcm_parameter_dma` and `pcm_parameter_voice_scheduler` share the GPL sample fetcher/cache and retain the original ordered mixer semantics. `SC88DMA1` contains genuine external host configuration and the 22 PC control fields only. The multi-voice parameter observer, normalizer and adapted testbenches are GPL-3.0-only; assertion state and synthetic/ROM-derived generated evidence remain under `build/`.
- ROMs and private ROM-derived PCM/DSP snapshots are user-provided/local data and are excluded from the source repository.
- Phase 3: the same XP observation overlay records the already-computed four-send mixer frame and observes all active Voices. `multivoice_vectors.cpp` executes the pinned XP for 1/8/32/64 Voice scenarios, exporting state, ROM access, send order and no-DSP IRAM results. The hook does not replace mixer arithmetic or DSP execution. Generator and observer remain GPL-3.0-only; all generated evidence stays in `build/`.
- Phase 3 handwritten RTL: `pcm_voice_scheduler`, `pcm_mixer`, `pcm_sample_cache`, `pcm_sample_fetcher` and `pcm_frame_fifo` are GPL-3.0-only. The mixer preserves the pinned XP send order, fixed-point contribution and per-deposit saturation; AXI, cache and whole-frame buffering are handwritten RTL. Testbench ROM bytes use the public synthetic formula; private ROM data is not embedded in these modules.
- Phase 2 HLS: `hls/prepare_core.py` generates GPL-3.0-only numerical derivatives of the pinned XP Voice source and fixed-point helpers under `build/hls-source`. It preserves the reference expressions, bounds source-fetch loops, fixes the exported pitch table, uses explicit ROM request/response arguments and caller-owned packed state, and expresses signed booster scaling as multiplication. Original coefficient acknowledgements are retained. The generator, HLS top and testbench belong to the corresponding source; ROM-derived vectors remain private. The target-device resource gate has not passed.

Project-owned C++ reference/Trace code is marked `SPDX-License-Identifier: GPL-3.0-only`. A distribution of the linked programs must include the applicable license and corresponding source, including the observation generator; this project does not grant rights to distribute Roland ROM data. Register traces, program/coefficient snapshots, and audio remain private local generated data.

## Phase 4 board integration

Project-owned board RTL and PS C code are GPL-3.0-only. Codec register values are implemented from the Analog Devices SSM2603 data sheet. Vivado XPM FIFO/CDC simulation uses the installed AMD tool libraries; those library sources are not copied into this repository.

`prepare_board_probe.py` observes bounded real MIDI Trace windows using the pinned replay and XP observation overlay. All 64 Voice post-states are assertions; the command export contains one initial state and changes caused by intervening external controls. The diagnostic mixer observer applies the pinned `dspOps::stepMixerCycle` to a separate, initially cleared mixer state, preserving the source replay's XP DSP/LSP execution. It represents Phase 4 direct mixer cells, not the complete final effects output. Probe, observation hooks and generators are GPL-3.0-only; original Touhou MIDI, decoded ROM and all derived windows remain private local data.

`hardware/board/zybo_ps7.tcl` retains the Digilent original Zybo PS7 preset, sourced through the local PC-98 board configuration. Its upstream source is https://github.com/Digilent/vivado-boards/tree/master/new/board_files/zybo/B.3. No PC-98 audio core or build artifact is used.

Copyright (c) 2021 Digilent

`software/ps/lscript.ld` is the AMD Cortex-A9 bare-metal linker layout, copied through the permitted local board-build reference with its header retained. Copyright (C) 2023 Advanced Micro Devices, Inc. The following MIT permission also applies to that linker script.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Offline parameter Phase 4 USB Host

TinyUSB 0.21.0 (`dae3f9a366bfcddbf9dcf1b48d7500286a849539`) is obtained from https://github.com/hathach/tinyusb and used under its MIT license. Preserve `external/tinyusb/LICENSE` with redistributed source and binaries. The upstream checkout is unmodified; Zynq integration is in `software/ps/sc88_usb_zynq.c`. `host/prepare_usb_host.py` generates the build copy with bounded EHCI transaction-error recovery, retaining the upstream license. The recovery limit and token re-arm follow the behavior of [Linux EHCI](https://github.com/torvalds/linux/blob/master/drivers/usb/host/ehci-q.c); no SCSI command or file read is replayed.

The storage diagnostic uses FatFs R0.15a from the installed Vitis 2025.2 `xilffs_v5_5`. The ChaN copyright, redistribution condition and disclaimer in `ff.c` and its headers must accompany redistributed source; AMD additions retain their supplied notices. Project disk I/O is read-only and does not link the SDK SD/RAM disk implementation.
