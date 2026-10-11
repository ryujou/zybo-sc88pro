"""Exercise the actual MSC disk adapter with completion, disconnect and timeout injection."""
import os
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/storage-disk"
PLATFORM = ROOT / "build/verification/offline-player/phase-04/storage-platform"
FATFS = (Path(os.environ["VITIS_ROOT"]) / "data/embeddedsw/lib/sw_services/xilffs_v5_5/src/include")
SOURCE = r'''
#include "sc88_storage.h"
#include "tusb.h"
#include "diskio.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static unsigned scenario, submitted, audio_calls, ticks, remaining;
static unsigned pending_lba, pending_count;
static void *pending_buffer;
static tuh_msc_complete_cb_t callback;
static uint32_t sector_size;
void XTime_GetTime(uint64_t *time) { *time = (uint64_t)++ticks * 1000; }
bool tusb_rhport_init(uint8_t port, const tusb_rhport_init_t *init) {
    assert(port == 0 && init->role == TUSB_ROLE_HOST); return true;
}
uint32_t tuh_msc_get_block_size(uint8_t device, uint8_t lun) { assert(device==1 && lun==0);return sector_size; }
uint32_t tuh_msc_get_block_count(uint8_t device, uint8_t lun) { (void)device;(void)lun;return 1000; }
bool tuh_msc_read10(uint8_t device, uint8_t lun, void *buffer, uint32_t lba,
                    uint16_t count, tuh_msc_complete_cb_t cb, uintptr_t arg) {
    (void)arg;assert(device==1 && lun==0);assert(((uintptr_t)buffer&31)==0);
    assert(count*sector_size<=16384);++submitted;
    if(scenario==5) return false;
    pending_buffer=buffer;pending_lba=lba;pending_count=count;callback=cb;remaining=3;
    return true;
}
void sc88_usb_poll(void) {
    if(!callback || scenario==3) return;
    if(scenario==2) { tuh_msc_umount_cb(1);callback=NULL;return; }
    if(--remaining) return;
    for(unsigned n=0;n<pending_count*sector_size;++n)
        ((uint8_t*)pending_buffer)[n]=(uint8_t)(pending_lba*sector_size+n);
    msc_cbw_t cbw={.tag=123};
    msc_csw_t csw={.signature=MSC_CSW_SIGNATURE,.tag=123,.status=0};
    if(scenario==1) csw.status=1;
    if(scenario==6) csw.tag=124;
    if(scenario==7) csw.signature=0;
    if(scenario==8) csw.data_residue=1;
    const tuh_msc_complete_data_t data={.cbw=&cbw,.csw=&csw};
    tuh_msc_complete_cb_t done=callback;callback=NULL;done(1,&data);
}
static void audio(void) { ++audio_calls; }
int main(int argc,char **argv) {
    assert(argc==2);scenario=(unsigned)atoi(argv[1]);sector_size=scenario==4?4096:512;
    assert(sc88_storage_init(audio)==0);tuh_msc_mount_cb(1);
    static uint8_t output[40000];memset(output,0xa5,sizeof(output));
    assert(disk_read(0,output,999,2)==RES_PARERR && submitted==0);
    assert(disk_read(0,output,((LBA_t)1<<32)+2,1)==RES_PARERR && submitted==0);
    assert(disk_read(0,output,0,0)==RES_PARERR && submitted==0);
    const unsigned blocks=scenario==4?9:65;
    const DRESULT result=disk_read(0,output+1,2,blocks);
    if(scenario==0 || scenario==4) {
        assert(result==RES_OK && submitted==3 && audio_calls>=9);
        assert(sc88_storage_stats.read_bytes==blocks*sector_size);
        assert(output[0]==0xa5 && output[1+blocks*sector_size]==0xa5);
        for(unsigned i=0;i<blocks*sector_size;++i) assert(output[i+1]==(uint8_t)(2*sector_size+i));
        WORD size;assert(disk_ioctl(0,GET_SECTOR_SIZE,&size)==RES_OK && size==sector_size);
    } else {
        assert(result==RES_ERROR && sc88_storage_stats.faults);
        for(unsigned i=0;i<sizeof(output);++i) assert(output[i]==0xa5);
        assert(disk_read(0,output,0,1)==RES_NOTRDY && submitted==1);
        if(scenario==3) assert(audio_calls>=1000);
    }
    assert(disk_write(0,output,0,1)==RES_WRPRT);
    return 0;
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "xtime_l.h").write_text("#include <stdint.h>\ntypedef uint64_t XTime;\n#define COUNTS_PER_SECOND 1000000u\nvoid XTime_GetTime(XTime*);\n", encoding="utf-8")
    (OUT / "test.c").write_text(SOURCE, encoding="utf-8")
    cc = str(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe")
    exe = OUT / "storage_disk_test.exe"
    command = [cc, "-std=c11", "-O2", "-Wall", "-Wextra",
               "-include", str(ROOT / "software/ps/sc88_fatfs_config.h"),
               "-I", str(OUT), "-I", str(ROOT / "software/ps"),
               "-I", str(ROOT / "external/tinyusb/src"), "-I", str(FATFS),
               "-I", str(PLATFORM / "bsp/ps7_cortexa9_0/include"), str(OUT / "test.c"),
               str(ROOT / "software/ps/sc88_storage.c"), "-o", str(exe)]
    result = subprocess.run(command, capture_output=True, text=True)
    (OUT / "compile.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    result.check_returncode()
    cases = ["512_byte_unaligned_caller_chunked", "SCSI_failure", "disconnect", "timeout_audio_service",
             "4096_byte_sector", "submission_failure", "wrong_tag", "wrong_signature", "residual_data"]
    for index, name in enumerate(cases):
        subprocess.run([str(exe), str(index)], check=True)
        print(name + ": passed", flush=True)
    report = dict(success=True, scope="MSC_disk_adapter_mock_transport", hardware_verified=False, cases=cases)
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
