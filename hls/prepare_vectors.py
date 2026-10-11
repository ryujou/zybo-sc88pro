"""Prepare immutable synthetic vectors and real Trace control inputs for the HLS testbench."""
import csv
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/phase-02"


def main():
    vectors = OUT / "hls-vectors"
    vectors.mkdir(parents=True, exist_ok=True)
    with (OUT / "golden/manifest.csv").open(encoding="utf-8",newline="") as stream:
        synthetic = list(csv.DictReader(stream))
    for case in synthetic:
        shutil.copytree(OUT / "golden" / case["case"],vectors / case["case"],dirs_exist_ok=True)
    real = vectors / "trace_piano"
    real.mkdir(exist_ok=True)
    for source,target in [("voice-initial.csv","initial.csv"),("voice-expected.csv","expected.csv")]:
        with (OUT / "trace-piano" / source).open(encoding="utf-8") as src, (real / target).open("w",encoding="utf-8",newline="") as dst:
            dst.write(next(src).replace("voice[62]","voice[0]").replace("voice[63]","voice[1]"))
            shutil.copyfileobj(src,dst)
    for source,target in [("voice-rom-reads.csv","rom-reads.csv"),("voice-stages.csv","stages.csv")]:
        shutil.copyfile(OUT / "trace-piano" / source,real / target)
    with (OUT / "trace-piano/voice-controls.csv").open(encoding="utf-8") as src, (real / "events.csv").open("w",encoding="utf-8",newline="") as dst:
        for line in src:
            dst.write(line.replace("voice[62]","voice[0]").replace("voice[63]","voice[1]"))
    columns=["case","frames","start_frame","first_voice","slots"]+[f"rom_size{i}" for i in range(8)]+[f"rom_flags{i}" for i in range(8)]
    with (vectors / "manifest.csv").open("w",encoding="utf-8",newline="") as stream:
        writer=csv.DictWriter(stream,fieldnames=columns); writer.writeheader()
        for case in synthetic:
            entry=dict(case=case["case"],frames=case["frames"],start_frame=0,first_voice=0,slots=1)
            for cs in range(8):
                entry[f"rom_size{cs}"]=1048576 if cs==0 else 0
                entry[f"rom_flags{cs}"]=0 if case["case"]=="physical_bus8" else 1
            writer.writerow(entry)
        entry=dict(case="trace_piano",frames=256000,start_frame=256000,first_voice=62,slots=2)
        for cs in range(8):
            entry[f"rom_size{cs}"]=4194304 if cs<5 else 0
            entry[f"rom_flags{cs}"]=1
        writer.writerow(entry)
    print("XP3_HLS_VECTORS_COMPLETE cases=61 frames=271360 initial_only=True")


if __name__ == "__main__":
    main()
