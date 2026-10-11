"""Build the USB parameter diagnostic player for the specified parameter-platform XSA."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import zipfile
from prepare_usb_host import prepare_ehci

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-ps"
VITIS = Path(os.environ["VITIS_ROOT"])
ARM = VITIS / "gnu/aarch32/nt/gcc-arm-none-eabi/bin"


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--xsa", type=Path, default=OUT.parent / "board/sc88.xsa")
    parser.add_argument("--capture-first", type=int, help="Build a diagnostic ELF that captures 2048 frames of raw results and returned PCM")
    parser.add_argument("--effects", action="store_true", help="Use the XP/LSP interpreter on ordered PL sends")
    args = parser.parse_args()
    if args.capture_first is not None:
        if not 0 <= args.capture_first <= 0xffffffff - 2048:
            parser.error("--capture-first is outside the supported frame range")
        OUT = OUT.parent / "parameter-capture-ps"
    if args.effects:
        OUT = OUT.parent / "parameter-effects-ps"
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["XILINX_VITIS"] = str(VITIS)
    env["PATH"] = os.pathsep.join([str(ARM), str(VITIS / "gnuwin/bin"), env["PATH"]])
    report = dict(scope="PS_USB_parameter_diagnostic_player", success=False, hardware_verified=False)
    def run(command, log):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        (OUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
        result.check_returncode()
        return result.stdout
    try:
        xsa = args.xsa.resolve()
        with zipfile.ZipFile(xsa) as archive:
            init = [n for n in archive.namelist() if n.rsplit("/", 1)[-1] == "ps7_init.tcl"]
            assert len(init) == 1
            (OUT / "ps7_init.tcl").write_bytes(archive.read(init[0]))
            report["xsa_contains_bit"] = any(n.endswith(".bit") for n in archive.namelist())
        report["xsa"] = str(xsa)
        bsp = OUT / "bsp"
        log = run([VITIS / "bin/xsct.bat", ROOT / "scripts/build_board_ps.tcl", xsa, bsp], "bsp-generate.log")
        assert "SC88_PS_BSP_COMPLETE" in log
        run([VITIS / "gnuwin/bin/make.exe", "-C", bsp, "SHELL=cmd.exe"], "bsp-build.log")
        platform = bsp / "ps7_cortexa9_0"
        fatfs = VITIS / "data/embeddedsw/lib/sw_services/xilffs_v5_5/src"
        flags = ["-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-O2", "-flto", "-g", "-std=c11",
                 "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections",
                 "-include", ROOT / "software/ps/sc88_fatfs_config.h",
                 "-I", platform / "include", "-I", ROOT / "software/ps",
                 "-I", ROOT / "external/tinyusb/src", "-I", fatfs / "include",
                 "-I", ROOT / "external/tinyusb/src/portable/ehci"]
        if args.capture_first is not None:
            flags.append(f"-DSC88_PARAMETER_CAPTURE_FIRST={args.capture_first}ULL")
            report["capture"] = dict(first_frame=args.capture_first, frames=2048, words_per_frame=323,
                                     address=0x08000000, layout="frame, result_count, returned_stereo_PCM, raw_results[320]")
        if args.effects:
            flags.append("-DSC88_PARAMETER_EFFECTS=1")
        names = ["parameter_main", "sc88_storage", "sc88_usb_zynq", "sc88_codec", "sc88_parameter_files",
                 "sc88_parameter_service", "sc88_parameter_audio", "sc88_parameter_blocks", "sc88_frame_prepare",
                 "sc88_parameter_reader", "sc88_parameter_frame", "sc88_host_config"]
        sources = [ROOT / "software/ps" / (name + ".c") for name in names]
        sources += [ROOT / "external/tinyusb/src" / name for name in
                    ["tusb.c", "common/tusb_fifo.c", "host/usbh.c", "class/msc/msc_host.c"]]
        sources.append(prepare_ehci(OUT))
        sources += [fatfs / "ff.c", fatfs / "ffunicode.c"]
        objects = []
        for source in sources:
            target = OUT / (source.stem + ".o")
            warnings = ["-Werror"] if source.stem in names else []
            run([ARM / "arm-none-eabi-gcc.exe", *flags, *warnings, "-c", source, "-o", target], source.stem + "-compile.log")
            objects.append(target)
        elf = OUT / "parameter_player.elf"
        compiler = "arm-none-eabi-gcc.exe"
        libraries = []
        if args.effects:
            from prepare_effects import prepare
            overlay = prepare()
            cppflags = [f for f in flags if f != "-std=c11"]
            cppflags += ["-std=c++17", "-DCHIPS_FORCE_NO_JIT=1", "-fno-threadsafe-statics", "-I", overlay]
            cpp_sources = [ROOT / "software/ps/sc88_parameter_effects.cpp"]
            cpp_sources += [overlay / "custom_chips/xp" / (name + ".cpp") for name in
                            ["xp", "xp_host", "xp_dsp", "xp_dsp_program", "xp_dsp_naive"]]
            for source in cpp_sources:
                target = OUT / (source.stem + ".o")
                run([ARM / "arm-none-eabi-g++.exe", *cppflags, "-c", source, "-o", target], source.stem + "-compile.log")
                objects.append(target)
            compiler = "arm-none-eabi-g++.exe"
            libraries = ["-lstdc++", "-lm"]
            # XP reset uses a temporary state; LSP owns its program and delay RAM on the heap.
            flags += ["-Wl,--defsym,_STACK_SIZE=0x100000", "-Wl,--defsym,_HEAP_SIZE=0x400000"]
        run([ARM / compiler, *flags,
             "-specs=" + str(VITIS / "data/embeddedsw/scripts/specs/arm/Xilinx.spec"), "-specs=nosys.specs",
             "-Wl,--gc-sections", "-Wl,-u,_vector_table", "-Wl,-Map," + str(OUT / "parameter_player.map"),
             "-Wl,-T," + str(ROOT / "software/ps/lscript.ld"), *objects, "-L", platform / "lib",
             "-Wl,--start-group", "-lxil", *libraries, "-lc", "-lgcc", "-Wl,--end-group", "-o", elf], "link.log")
        data = elf.read_bytes()
        assert data[:7] == b"\x7fELF\x01\x01\x01" and struct.unpack_from("<H", data, 18)[0] == 40
        phoff = struct.unpack_from("<I", data, 28)[0]
        phsize, phcount = struct.unpack_from("<HH", data, 42)
        segments = []
        for index in range(phcount):
            kind, _, _, address, _, size, _, _ = struct.unpack_from("<8I", data, phoff + index * phsize)
            if kind == 1 and size:
                assert 0x100000 <= address and address + size <= 0x1000000
                segments.append(dict(address=address, bytes=size))
        assert segments
        symbols = run([ARM / "arm-none-eabi-nm.exe", "-n", elf], "symbols.log")
        # LTO can inline or specialize the player and USB functions.
        assert any(line.endswith(" T main") for line in symbols.splitlines())
        if args.capture_first is not None:
            assert any(line.endswith(" sc88_parameter_capture_frames") for line in symbols.splitlines())
        sizes = run([ARM / "arm-none-eabi-size.exe", elf], "size.log")
        report.update(success=True, segments=segments, size=sizes.strip(), elf=str(elf.relative_to(ROOT)),
                      limitation="Build only; diagnostic mixer cells 8/9, no XP DSP/LSP or hardware evidence. Deployment requires the matching full-board bit/XSA to pass.")
        if args.effects:
            report.update(scope="PS_USB_parameter_effects_player", limitation="Build only; XP/LSP on PL sends. ARM real-time performance and hardware PCM are unverified.")
        print(json.dumps(report), flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
