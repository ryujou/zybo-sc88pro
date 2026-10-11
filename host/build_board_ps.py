"""Build the Cortex-A9 BSP/ELF from this project's bit-inclusive XSA."""
import json
import os
from pathlib import Path
import struct
import subprocess
import zipfile
from phase4 import ROOT,OUT

VITIS=Path(os.environ["VITIS_ROOT"])


def main():
    out=OUT/"ps";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    arm=VITIS/"gnu/aarch32/nt/gcc-arm-none-eabi/bin"
    environment=os.environ.copy()
    environment["XILINX_VITIS"]=str(VITIS)
    environment["PATH"]=os.pathsep.join([str(arm),str(VITIS/"gnuwin/bin"),environment.get("PATH","")])
    def execute(command,name):
        result=subprocess.run(list(map(str,command)),cwd=ROOT,env=environment,capture_output=True,text=True,encoding="utf-8",errors="replace")
        (out/name).write_text(result.stdout+result.stderr,encoding="utf-8")
        if result.returncode:raise RuntimeError(f"PS build failed; see {out/name}")
        return result.stdout
    try:
        board=OUT/"board";xsa=board/"sc88.xsa"
        assert json.loads((board/"summary.json").read_text(encoding="utf-8"))["success"],"Full-board resource, STA, DRC and CDC audit must pass before building the PS image"
        with zipfile.ZipFile(xsa) as archive:
            bits=[n for n in archive.namelist() if n.endswith(".bit")]
            assert len(bits)==1 and archive.read(bits[0])==(board/"sc88.bit").read_bytes(),"XSA does not contain the current bitstream"
            init=[n for n in archive.namelist() if n.rsplit("/",1)[-1]=="ps7_init.tcl"]
            assert len(init)==1,"XSA PS7 initialization entry missing"
            (out/"ps7_init.tcl").write_bytes(archive.read(init[0]))
        bsp=out/"bsp"
        generated=execute([VITIS/"bin/xsct.bat",ROOT/"scripts/build_board_ps.tcl",xsa,bsp],"bsp-generate.log")
        assert "SC88_PS_BSP_COMPLETE" in generated,"XSCT did not complete BSP generation; see bsp-generate.log"
        execute([VITIS/"gnuwin/bin/make.exe","-C",bsp,"SHELL=cmd.exe"],"bsp-build.log")
        platform=bsp/"ps7_cortexa9_0"
        sources=ROOT/"software/ps"
        flags=["-mcpu=cortex-a9","-mfpu=vfpv3","-mfloat-abi=hard","-O2","-g","-std=c11","-Wall","-Wextra","-ffunction-sections","-fdata-sections","-I",platform/"include","-I",sources]
        objects=[]
        for name in ["main","sc88_codec","sc88_trace","sc88_player"]:
            target=out/(name+".o");objects.append(target)
            execute([arm/"arm-none-eabi-gcc.exe",*flags,"-c",sources/(name+".c"),"-o",target],name+"-compile.log")
        elf=out/"sc88.elf"
        execute([arm/"arm-none-eabi-gcc.exe",*flags,
            "-specs="+str(VITIS/"data/embeddedsw/scripts/specs/arm/Xilinx.spec"),"-specs=nosys.specs",
            "-Wl,--gc-sections","-Wl,-u,_vector_table","-Wl,-Map,"+str(out/"sc88.map"),"-Wl,-T,"+str(sources/"lscript.ld"),
            *objects,"-L",platform/"lib","-Wl,--start-group","-lxil","-lc","-lgcc","-Wl,--end-group","-o",elf],"link.log")
        data=elf.read_bytes()
        assert data[:7]==b"\x7fELF\x01\x01\x01" and struct.unpack_from("<H",data,18)[0]==40,"Expected little-endian ARM ELF32"
        phoff=struct.unpack_from("<I",data,28)[0];phsize,phcount=struct.unpack_from("<HH",data,42)
        segments=[]
        for index in range(phcount):
            kind,offset,vaddr,paddr,filesize,memsize,flags_value,alignment=struct.unpack_from("<8I",data,phoff+index*phsize)
            if kind==1 and memsize:
                assert 0x00100000<=paddr and paddr+memsize<=0x01000000,"ELF overlaps DMA/ROM memory"
                segments.append(dict(address=paddr,bytes=memsize,file_bytes=filesize))
        assert segments
        sizes=execute([arm/"arm-none-eabi-size.exe",elf],"size.log")
        execute([arm/"arm-none-eabi-nm.exe","-n",elf],"symbols.log")
        summary.update(success=True,xsa=str(xsa.relative_to(ROOT)),elf=str(elf.relative_to(ROOT)),segments=segments,size=sizes.strip())
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
