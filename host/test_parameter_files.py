"""Exercise real A/B prefetch code with a file-backed FatFs API test transport."""
import os
import json
from pathlib import Path
import subprocess
import struct
import zlib
from test_parameter_reader import header, block, event

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/verification/offline-player/phase-04/parameter-files"
SOURCE=r'''
extern "C" {
#include "sc88_parameter_files.h"
}
#include <cassert>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <vector>
static sc88_parameter_files files;
static FILE *input;
static unsigned reads, callback_events, callbacks, switches, scenario;
static bool consuming;
static uint64_t events;
static FRESULT read_error=FR_OK;
extern "C" FRESULT f_open(FIL *file,const TCHAR *path,BYTE mode) {
    assert(!input && mode==FA_READ);
    if(scenario==1) return FR_NOT_READY;
    input=std::fopen(path,"rb");
    if(input) {file->fptr=0;file->obj.objsize=std::filesystem::file_size(path);}
    return input?FR_OK:FR_NO_FILE;
}
extern "C" FRESULT f_read(FIL *file,void *data,UINT bytes,UINT *got) {
    assert(input && bytes<=16384);++reads;
    for(auto& slot:files.buffers) {
        auto p=(uintptr_t)data,a=(uintptr_t)slot.data;
        if(p>=a && p<a+SC88_FILE_BUFFER_BYTES) {
            assert(slot.owner==SC88_FILE_FILLING && p+bytes<=a+SC88_FILE_BUFFER_BYTES);
        }
    }
    if(scenario==2 && reads==2) { *got=0;return FR_DISK_ERR; }
    *got=(UINT)std::fread(data,1,bytes,input);
    file->fptr+=*got;
    return std::ferror(input)?FR_DISK_ERR:read_error;
}
extern "C" FRESULT f_close(FIL*) {
    assert(input);int result=std::fclose(input);input=nullptr;
    return scenario==3?FR_DISK_ERR:result?FR_DISK_ERR:FR_OK;
}
extern "C" FRESULT f_stat(const TCHAR *path,FILINFO *info) {
    if(scenario==4) return FR_DISK_ERR;
    if(!std::filesystem::exists(path)) return FR_NO_FILE;
    std::memset(info,0,sizeof(*info));return FR_OK;
}
static int consume(unsigned count) {
    int status=0;
    for(unsigned n=0;n<count;++n) {
        sc88_parameter_event event;
        unsigned previous=files.consumer;
        status=sc88_parameter_files_next(&files,&event);
        if(previous!=files.consumer) ++switches;
        if(status!=1) break;
        ++events;
    }
    return status;
}
extern "C" void sc88_storage_poll() {
    ++callbacks;
    if(consuming) {
        uint64_t before=events;
        int status=consume(512);assert(status>=0 || scenario);
        callback_events+=(unsigned)(events-before);
    }
}
int main(int argc,char**argv) {
    assert(argc>=3);scenario=(unsigned)std::stoul(argv[1]);
    std::vector<uint8_t> a(SC88_FILE_BUFFER_BYTES),b(SC88_FILE_BUFFER_BYTES);
    for(int index=2;index<argc;++index) {
        reads=callback_events=callbacks=switches=0;events=0;consuming=false;
        int status=sc88_parameter_files_open(&files,argv[index],a.data(),b.data());
        if(scenario==1) {assert(status<0 && !input);std::cout<<"open_fault\n";continue;}
        assert(!status);
        status=sc88_parameter_files_fill(&files);
        if(status<0) {
            assert(scenario && files.fault && sc88_parameter_files_next(&files,nullptr)<0);
            sc88_parameter_files_close(&files);assert(!input);std::cout<<"fault "<<files.fault<<'\n';continue;
        }
        status=sc88_parameter_files_fill(&files);assert(status>=0);
        // Both slots are owned; filling again cannot touch either one.
        unsigned old_reads=reads;
        assert(sc88_parameter_files_fill(&files)==0 && reads==old_reads);
        consuming=true;
        unsigned iterations=0;
        while((status=consume(1024))!=2 && status>=0) {
            int filled=sc88_parameter_files_fill(&files);
            if(filled<0) {status=-1;break;}
            assert(++iterations<10000000);
        }
        if(scenario) assert(status<0 && files.fault);
        else {
            assert(status==2 && files.reader.complete && !files.fault);
            std::cout<<index-1<<' '<<files.reader.frame<<' '<<events<<' '<<files.bytes_read<<' '
                     <<callbacks<<' '<<callback_events<<' '<<switches<<'\n';
        }
        assert(!sc88_parameter_files_close(&files));assert(!input);
    }
}
'''

FAT_SOURCE=r'''
#include "sc88_parameter_files.h"
#include "diskio.h"
#include "xil_cache.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static FILE *disk;
void Xil_DCacheFlushRange(INTPTR address,u32 bytes) { (void)address;(void)bytes; }
DSTATUS disk_initialize(BYTE drive) { return drive?STA_NOINIT:STA_PROTECT; }
DSTATUS disk_status(BYTE drive) { return disk_initialize(drive); }
DRESULT disk_read(BYTE drive,BYTE *data,LBA_t sector,UINT count) {
    if(drive || fseek(disk,(long)sector*512,SEEK_SET)) return RES_ERROR;
    return fread(data,512,count,disk)==count?RES_OK:RES_ERROR;
}
DRESULT disk_write(BYTE drive,const BYTE *data,LBA_t sector,UINT count) {
    (void)drive;(void)data;(void)sector;(void)count;return RES_WRPRT;
}
DRESULT disk_ioctl(BYTE drive,BYTE command,void *buffer) {
    if(drive) return RES_PARERR;
    if(command==GET_SECTOR_SIZE) {*(WORD*)buffer=512;return RES_OK;}
    if(command==GET_SECTOR_COUNT) {*(LBA_t*)buffer=32768;return RES_OK;}
    if(command==GET_BLOCK_SIZE) {*(DWORD*)buffer=1;return RES_OK;}
    return command==CTRL_SYNC?RES_OK:RES_PARERR;
}
void sc88_storage_poll(void) {}
int main(int argc,char **argv) {
    assert(argc==2);
    disk=fopen(argv[1],"rb");assert(disk);
    FATFS fs;assert(f_mount(&fs,"0:",1)==FR_OK);
    uint8_t *a=malloc(SC88_FILE_BUFFER_BYTES),*b=malloc(SC88_FILE_BUFFER_BYTES);assert(a&&b);
    sc88_parameter_files files;
    assert(!sc88_parameter_files_open(&files,"0:/segmented-song.scp",a,b));
    unsigned records=0;int status;
    do {
        assert(sc88_parameter_files_fill(&files)>=0);
        sc88_parameter_event event;
        while((status=sc88_parameter_files_next(&files,&event))==1) ++records;
        assert(status>=0);
    } while(status!=2);
    assert(records==4 && files.reader.frame==2 && files.reader.segment==1);
    assert(!sc88_parameter_files_close(&files));
    assert(f_mount(NULL,"0:",0)==FR_OK);assert(!fclose(disk));free(a);free(b);
    printf("Actual FatFs %s + LFN + consecutive parameter segments passed\n",argv[1]);
    return 0;
}
'''


def fat_image(files):
    image=bytearray(32768*512)
    image[:11]=b"\xeb\x3c\x90SC88TEST"
    struct.pack_into("<HBHBHHBHHHII",image,11,512,1,1,2,512,32768,0xf8,128,32,64,0,0)
    image[36:39]=b"\x80\0\x29"
    image[43:54]=b"SC88 TEST  "
    image[54:62]=b"FAT16   "
    image[510:512]=b"\x55\xaa"
    fat=bytearray(128*512);struct.pack_into("<HH",fat,0,0xfff8,0xffff)
    entry=0;cluster=2;data_start=1+256+32
    for index,(name,data) in enumerate(files,1):
        alias=f"SEGME~{index:02d}SCP".encode();assert len(alias)==11
        # FAT long-name entries require the short-name checksum as part of their on-disk format.
        checksum=0
        for byte in alias: checksum=(((checksum&1)<<7)+(checksum>>1)+byte)&255
        chars=list(struct.unpack(f"<{len(name)}H",name.encode("utf-16le")))+[0]
        while len(chars)%13: chars.append(0xffff)
        count=len(chars)//13
        for ordinal in range(count,0,-1):
            record=bytearray(32);record[0]=ordinal|(0x40 if ordinal==count else 0)
            record[11]=0x0f;record[13]=checksum
            chunk=chars[(ordinal-1)*13:ordinal*13]
            for offset,value in zip([1,3,5,7,9,14,16,18,20,22,24,28,30],chunk):
                struct.pack_into("<H",record,offset,value)
            start=(1+256)*512+entry*32;image[start:start+32]=record;entry+=1
        record=bytearray(32);record[:11]=alias;record[11]=0x20
        struct.pack_into("<H",record,26,cluster);struct.pack_into("<I",record,28,len(data))
        start=(1+256)*512+entry*32;image[start:start+32]=record;entry+=1
        needed=(len(data)+511)//512
        for n in range(needed): struct.pack_into("<H",fat,(cluster+n)*2,0xffff if n+1==needed else cluster+n+1)
        start=(data_start+cluster-2)*512;image[start:start+len(data)]=data;cluster+=needed
    image[512:129*512]=fat;image[129*512:257*512]=fat
    return image


def gpt_image(volume):
    start=2048
    sectors=start+len(volume)//512+33
    image=bytearray(sectors*512)
    image[446+4]=0xee
    struct.pack_into("<II",image,446+8,1,sectors-1)
    image[510:512]=b"\x55\xaa"
    table=bytearray(128*128)
    table[:16]=bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7")
    table[16:32]=bytes(range(16))
    struct.pack_into("<QQQ",table,32,start,sectors-34,0)
    image[1024:1024+len(table)]=table
    header=bytearray(512)
    struct.pack_into("<8sIIIIQQQQ16sQIII",header,0,b"EFI PART",0x10000,92,0,0,
                     1,sectors-1,34,sectors-34,bytes(range(16)),2,128,128,zlib.crc32(table))
    # CRC fields are required by the GPT on-disk format.
    struct.pack_into("<I",header,16,zlib.crc32(header[:92]))
    image[512:1024]=header
    image[start*512:start*512+len(volume)]=volume
    return image


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,hardware_verified=False,scope="FatFs_API_prefetch_AB_ownership")
    (OUT/"summary.json").write_text(json.dumps(report),encoding="utf-8")
    def run(command,log):
        result=subprocess.run(list(map(str,command)),cwd=OUT,capture_output=True,text=True)
        (OUT/log).write_text(result.stdout+result.stderr,encoding="utf-8");result.check_returncode();return result.stdout
    compiler=(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin")
    ps=ROOT/"software/ps"
    fatfs=(Path(os.environ["VITIS_ROOT"]) / "data/embeddedsw/lib/sw_services/xilffs_v5_5/src/include")
    bsp=ROOT/"build/verification/offline-player/phase-04/storage-platform/bsp/ps7_cortexa9_0/include"
    flags=["-O2","-Wall","-Wextra","-Werror","-include",ps/"sc88_fatfs_config.h",
           "-I",ps,"-I",fatfs,"-I",bsp]
    objects=[]
    for name in ["sc88_parameter_files","sc88_parameter_reader"]:
        obj=OUT/(name+".o");objects.append(obj)
        run([compiler/"gcc.exe","-std=c11",*flags,"-c",ps/(name+".c"),"-o",obj],name+".log")
    arm=(Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
    run([arm,"-std=c11",*flags,"-mcpu=cortex-a9","-mfpu=vfpv3","-mfloat-abi=hard","-c",
         ps/"sc88_parameter_files.c","-o",OUT/"files-arm.o"],"arm-compile.log")
    (OUT/"test.cpp").write_text(SOURCE,encoding="utf-8")
    run([compiler/"g++.exe","-std=c++17",*flags,OUT/"test.cpp",*objects,"-o",OUT/"test.exe"],"link.log")
    exe=OUT/"test.exe"
    fixture=OUT/"segmented-song.scp"
    fixture.write_bytes(header()+block(0,0,0,[event(0,0,1),event(0,1,5)]))
    (OUT/"segmented-song.001.scp").write_bytes(header(1,1)+block(1,1,2,[event(1,0,5),event(2,0,8)]))
    run([exe,0,fixture,fixture],"segment-reopen.log")
    for scenario in range(1,5): run([exe,scenario,fixture],f"fault-{scenario}.log")
    short=OUT/"short.scp";short.write_bytes(header()+b"PBL1")
    run([exe,5,short],"truncated.log")
    bad=OUT/"bad.scp";bad.write_bytes(header()+block(0,0,0,[event(0,0,1),event(0,2,5)]))
    run([exe,5,bad],"malformed.log")
    volume=fat_image([(fixture.name,fixture.read_bytes()),
                     ("segmented-song.001.scp",(OUT/"segmented-song.001.scp").read_bytes())])
    (OUT/"fat16.img").write_bytes(volume)
    (OUT/"gpt-fat16.img").write_bytes(gpt_image(volume))
    (OUT/"fat_test.c").write_text(FAT_SOURCE,encoding="utf-8")
    run([compiler/"gcc.exe","-std=c11",*[f for f in flags if f!="-Werror"],
         OUT/"fat_test.c",fatfs.parent/"ff.c",fatfs.parent/"ffunicode.c",*objects,
         "-o",OUT/"fat_test.exe"],"fat-build.log")
    for name in ["fat16", "gpt-fat16"]:
        print(run([OUT/"fat_test.exe",name+".img"],name+"-test.log"),end="",flush=True)
    files=[ROOT/"build/verification/offline-player/phase-01/cases"/f"th06_{n:02d}"/"export/song.scp" for n in range(1,8)]
    print("ARM compile, segmented reopen and six fault cases passed; exercising A/B overlap on seven MIDI files",flush=True)
    output=run([exe,0,*files],"songs.log");print(output,end="",flush=True)
    previous=json.loads((ROOT/"build/verification/offline-player/phase-04/parameter-reader/summary.json").read_text(encoding="utf-8"))
    assert previous["success"]
    rows=[list(map(int,row.split())) for row in output.splitlines()];assert len(rows)==7
    songs=[]
    for row,known,path in zip(rows,previous["songs"],files):
        index,frames,records,bytes_read,callbacks,callback_events,switches=row
        assert (frames,records)==(known["frames"],known["records"])
        assert bytes_read==path.stat().st_size and callback_events>0 and switches>2
        songs.append(dict(song=known["song"],frames=frames,records=records,bytes=bytes_read,
                          service_callbacks=callbacks,events_consumed_during_fill=callback_events,buffer_switches=switches))
    report.update(success=True,arm_compile=True,segmented_reopen=True,fault_cases=6,songs=songs,
                  real_FatFs_FAT16_LFN_segment_read=True,
                  real_FatFs_GPT_partition_read=True,
                  limitation="Seven-song ownership test uses host files; actual FatFs uses local FAT16 and GPT/FAT16 images. USB performance and hardware remain unverified")
    (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
