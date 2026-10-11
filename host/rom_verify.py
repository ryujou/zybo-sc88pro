"""Strict SC-88Pro 1.02 ROM identification against the pinned upstream registry."""
import argparse
import hashlib
import json
import os
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "reference/phase0-contract.json"
REGISTRY = ROOT / "external/gearmulator/source/ronaldo/88emu/88lib/rom/romRegistry.h"


def load_targets():
    targets = json.loads(CONTRACT.read_text())["roms"]
    source = REGISTRY.read_text()
    for target in targets:
        slot = "Control" if target["role"] == "control" else "Wave"
        pattern = rf'\{{romDevices\(RomDevice::Sc88Pro[^}}]*RomSlot::{slot},\s*{target["slot"]},\s*0x{target["size"]:x},\s*baseLib::MD5\("{target["md5"]}"\)'
        if not re.search(pattern, source):
            raise ValueError(f"Target differs from Gearmulator registry: {target['role']}")
    return targets


def swap_pairs(data):
    swapped = bytearray(data)
    swapped[0::2], swapped[1::2] = data[1::2], data[0::2]
    return bytes(swapped)


def identify(data, targets):
    candidates = [target for target in targets if target["size"] == len(data)]
    if not candidates:
        return None
    digest = hashlib.md5(data).hexdigest()
    for target in candidates:
        if digest == target["md5"]:
            return target, "cpu_order" if target["role"] == "control" else "raw_registered", digest
    if len(data) == 1048576:
        normalized = hashlib.md5(swap_pairs(data)).hexdigest()
        for target in candidates:
            if target["role"] == "control" and normalized == target["md5"]:
                return target, "word_swapped", digest
    return None


def resolve_source(explicit=""):
    for variable in ["SC88_ROM_DIR", "SC88_ROM_ARCHIVE"]:
        if os.environ.get(variable):
            return Path(os.environ[variable])
    private = ROOT / "private/roms"
    if private.is_dir() and any(private.iterdir()):
        return private
    if explicit:
        return Path(explicit)
    raise FileNotFoundError("No ROM source. Set SC88_ROM_DIR/SC88_ROM_ARCHIVE or pass --source.")


def scan(source, targets, extract=None):
    source = Path(source)
    selected = {}
    ignored = []
    sizes = {target["size"] for target in targets}

    def visit(name, data):
        match = identify(data, targets)
        if match is None:
            ignored.append({"source":name, "size":len(data), "reason":"not_a_target_sc88pro_rom"})
            return
        target, order, digest = match
        if target["role"] in selected:
            ignored.append({"source":name, "reason":"duplicate_target_content"})
            return
        selected[target["role"]] = {"source":name, "size":len(data), "source_md5":digest, "normalized_md5":target["md5"], "byte_order":order, "filename":target["name"]}
        if extract:
            extract.mkdir(parents=True, exist_ok=True)
            destination = extract / target["name"]
            if destination.exists() and destination.read_bytes() != data:
                raise FileExistsError(f"Existing ROM differs: {destination}")
            if not destination.exists():
                destination.write_bytes(data)

    if source.is_file() and zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            for entry in archive.infolist():
                if not entry.is_dir() and entry.file_size in sizes:
                    visit(entry.filename, archive.read(entry))
                elif not entry.is_dir():
                    ignored.append({"source":entry.filename, "size":entry.file_size, "reason":"non_target_size"})
    elif source.is_dir():
        for entry in sorted(source.rglob("*")):
            if entry.is_file():
                if entry.stat().st_size in sizes:
                    visit(str(entry.relative_to(source)), entry.read_bytes())
                else:
                    ignored.append({"source":str(entry.relative_to(source)), "size":entry.stat().st_size, "reason":"non_target_size"})
    else:
        raise FileNotFoundError(f"ROM directory or ZIP not found: {source}")
    missing = [target["role"] for target in targets if target["role"] not in selected]
    if missing:
        raise ValueError(f"Missing verified ROM roles: {', '.join(missing)}")
    return {"device":"SC-88Pro", "control_version":"1.02", "source":str(source), "success":True, "roms":selected, "ignored":ignored, "registry":str(REGISTRY.relative_to(ROOT))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="")
    parser.add_argument("--extract", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "build/verification/phase-00/roms.json")
    args = parser.parse_args()
    result = scan(resolve_source(args.source), load_targets(), args.extract)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for role, rom in result["roms"].items():
        print(f"{role}: {rom['size']} bytes, {rom['normalized_md5']}, {rom['byte_order']}")


if __name__ == "__main__":
    main()
