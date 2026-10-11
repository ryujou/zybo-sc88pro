"""Build the PS-only, read-only USB storage diagnostic; does not deploy it."""
import json
import os
from pathlib import Path
import struct
import subprocess
import zipfile
from prepare_usb_host import prepare_ehci

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/storage-platform"
VITIS = Path(os.environ["VITIS_ROOT"])
ARM = VITIS / "gnu/aarch32/nt/gcc-arm-none-eabi/bin"
TINYUSB_COMMIT = "dae3f9a366bfcddbf9dcf1b48d7500286a849539"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["XILINX_VITIS"] = str(VITIS)
    env["PATH"] = os.pathsep.join([str(ARM), str(VITIS / "gnuwin/bin"), env["PATH"]])

    def run(command, log):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        (OUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"Storage build failed: {OUT / log}")
        return result.stdout

    report = dict(success=False, scope="offline_parameter_storage_probe", hardware_verified=False)
    try:
        commit = run(["git", "-C", ROOT / "external/tinyusb", "rev-parse", "HEAD"], "tinyusb-version.log").strip()
        assert commit == TINYUSB_COMMIT, "Expected TinyUSB 0.21.0; see THIRD_PARTY_NOTICES.md"
        assert not run(["git", "-C", ROOT / "external/tinyusb", "status", "--porcelain"], "tinyusb-status.log").strip()
        log = run([VITIS.parent / "Vivado/bin/vivado.bat", "-mode", "batch", "-source",
                   ROOT / "hardware/board/storage_platform.tcl", "-notrace",
                   "-log", OUT / "vivado.log", "-journal", OUT / "vivado.jou"], "platform-build.log")
        assert "SC88_STORAGE_PLATFORM_COMPLETE" in log
        xsa = OUT / "storage.xsa"
        with zipfile.ZipFile(xsa) as archive:
            init = [n for n in archive.namelist() if n.rsplit("/", 1)[-1] == "ps7_init.tcl"]
            assert len(init) == 1
            (OUT / "ps7_init.tcl").write_bytes(archive.read(init[0]))
        bsp = OUT / "bsp"
        log = run([VITIS / "bin/xsct.bat", ROOT / "scripts/build_board_ps.tcl", xsa, bsp], "bsp-generate.log")
        assert "SC88_PS_BSP_COMPLETE" in log
        run([VITIS / "gnuwin/bin/make.exe", "-C", bsp, "SHELL=cmd.exe"], "bsp-build.log")
        platform = bsp / "ps7_cortexa9_0"
        fatfs = VITIS / "data/embeddedsw/lib/sw_services/xilffs_v5_5/src"
        flags = ["-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-O2", "-g", "-std=c11",
                 "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections",
                 "-include", ROOT / "software/ps/sc88_fatfs_config.h",
                 "-I", platform / "include", "-I", ROOT / "software/ps",
                 "-I", ROOT / "external/tinyusb/src", "-I", fatfs / "include",
                 "-I", ROOT / "external/tinyusb/src/portable/ehci"]
        # Xilffs uses this interface macro to enable its generic core. diskio.c is ours, not RAM/SD.
        sources = [ROOT / "software/ps" / (name + ".c") for name in
                   ["storage_probe", "sc88_storage", "sc88_usb_zynq"]]
        sources += [ROOT / "external/tinyusb/src" / name for name in
                    ["tusb.c", "common/tusb_fifo.c", "host/usbh.c", "class/msc/msc_host.c"]]
        sources.append(prepare_ehci(OUT))
        sources.append(fatfs / "ff.c")
        sources.append(fatfs / "ffunicode.c")
        objects = []
        for source in sources:
            target = OUT / (source.stem + ".o")
            run([ARM / "arm-none-eabi-gcc.exe", *flags, "-c", source, "-o", target], source.stem + "-compile.log")
            objects.append(target)
        elf = OUT / "storage_probe.elf"
        run([ARM / "arm-none-eabi-gcc.exe", *flags,
             "-specs=" + str(VITIS / "data/embeddedsw/scripts/specs/arm/Xilinx.spec"), "-specs=nosys.specs",
             "-Wl,--gc-sections", "-Wl,-u,_vector_table", "-Wl,-Map," + str(OUT / "storage_probe.map"),
             "-Wl,-T," + str(ROOT / "software/ps/lscript.ld"), *objects, "-L", platform / "lib",
             "-Wl,--start-group", "-lxil", "-lc", "-lgcc", "-Wl,--end-group", "-o", elf], "link.log")
        data = elf.read_bytes()
        assert data[:7] == b"\x7fELF\x01\x01\x01" and struct.unpack_from("<H", data, 18)[0] == 40
        phoff = struct.unpack_from("<I", data, 28)[0]
        phsize, phcount = struct.unpack_from("<HH", data, 42)
        segments = []
        for index in range(phcount):
            kind, offset, vaddr, address, file_bytes, size, attributes, alignment = struct.unpack_from("<8I", data, phoff + index * phsize)
            if kind == 1 and size:
                assert 0x100000 <= address and address + size <= 0x1000000
                segments.append(dict(address=address, bytes=size))
        assert segments
        symbols = run([ARM / "arm-none-eabi-nm.exe", "-n", elf], "symbols.log")
        for name in ["sc88_storage_probe", "sc88_storage_command", "disk_read", "f_read", "ehci_init", "tuh_msc_read10"]:
            assert any(line.endswith(" " + name) for line in symbols.splitlines()), name
        sizes = run([ARM / "arm-none-eabi-size.exe", elf], "size.log")
        report.update(success=True, tinyusb_commit=commit, fatfs="Vitis 2025.2 xilffs_v5_5 / R0.15a",
                      read_only=True, segments=segments, size=sizes.strip(), elf=str(elf.relative_to(ROOT)),
                      limit="PS-only storage diagnostic; no synth PL or hardware test")
        print(json.dumps(report), flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
