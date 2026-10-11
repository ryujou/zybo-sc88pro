param([ValidateRange(1,7)][int]$FirstSong = 2, [ValidateRange(1,7)][int]$LastSong = 7,
    [Parameter(Mandatory=$true)][string]$Port, [Parameter(Mandatory=$true)][string]$CableSerial,
    [Parameter(Mandatory=$true)][string]$AudioDevice)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$evidence = Join-Path $root 'build/verification/offline-player/effects/seven-songs'
$delivery = Join-Path $root 'build/recordings/touhou-th06'
New-Item -ItemType Directory -Force -Path $evidence,$delivery | Out-Null
$xsct = (Join-Path $env:VITIS_ROOT 'bin/xsct.bat')
$analysisPython = Join-Path $root 'build/audio-analysis-env/Scripts/python.exe'
$logPath = Join-Path $evidence 'startup.log'
$port = [System.IO.Ports.SerialPort]::new($Port,115200)
function Command-Line([string]$key, [int]$seconds) {
    $port.Write($key)
    $text = ''
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $seconds) {
        $text += $port.ReadExisting()
        if ($text -match "SC88 key=$key [^\r\n]*\r?\n") {
            $line = $Matches[0].Trim()
            $line | Add-Content -LiteralPath $logPath -Encoding utf8
            Write-Host $line
            if ($line -notmatch "key=$key rc=0 ") { throw $line }
            return $line
        }
        Start-Sleep -Milliseconds 100
    }
    $text | Add-Content -LiteralPath $logPath -Encoding utf8
    throw "No completed UART reply for $key in $seconds seconds"
}
if ($FirstSong -gt 1) {
    Copy-Item -LiteralPath (Join-Path $root 'build/verification/offline-player/effects/recording/th06_01-linein.wav') -Destination (Join-Path $delivery 'th06_01.wav') -Force
}
& $xsct scripts/parameter_jtag.tcl build/verification/offline-player/phase-04/board/sc88.xsa build/verification/offline-player/phase-04/board/sc88.bit build/verification/offline-player/phase-04/parameter-effects-ps/parameter_player.elf build/verification/offline-player/phase-04/parameter-effects-ps/ps7_init.tcl load $CableSerial 2>&1 | Tee-Object -FilePath (Join-Path $evidence 'jtag-load.log')
if ($LASTEXITCODE -ne 0) { throw 'JTAG loading failed' }
try {
    $port.Open()
    $port.ReadExisting() | Set-Content -LiteralPath $logPath -Encoding utf8
    $null = Command-Line 'h' 15
    Start-Sleep -Seconds 3
    $null = Command-Line 'w' 30
    foreach ($song in $FirstSong..$LastSong) {
        $name = 'th06_{0:00}' -f $song
        $case = Join-Path $evidence $name
        New-Item -ItemType Directory -Force -Path $case | Out-Null
        $logPath = Join-Path $case 'render.log'
        $nativeFrames = [long]((Get-Item "build/verification/offline-player/phase-01/cases/$name/reference/native.pcm").Length / 8)
        $total = $nativeFrames + 256000
        Write-Host "RENDER_START $name total=$total"
        if (!$port.IsOpen) { $port.Open() }
        $null = Command-Line ([string]$song) 60
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Seconds 10
            $status = Command-Line 's' 240
            if ($status -notmatch 'pl_fault=00000000 ps_fault=0 ' -or $status -notmatch 'usb_faults=0 retries=0 ') { throw $status }
            if ($status -match 'playing=0 ') {
                if ($status -notmatch "result=1 frames=$total ") { throw $status }
                break
            }
            if ($timer.Elapsed.TotalSeconds -gt 1800) { $port.Write('x'); throw 'Render exceeded 1800 seconds' }
        } while ($true)
        $port.Close()
        & $xsct scripts/dump_parameter_pcm.tcl $total (Join-Path $case 'board.pcm') $CableSerial 2>&1 | Tee-Object -FilePath (Join-Path $case 'dump.log')
        if ($LASTEXITCODE -ne 0) { throw "PCM dump failed: $name" }
        @'
import sys,json
from pathlib import Path
sys.path.insert(0,'host')
from sc88_audio_compare import compare
name,out=sys.argv[1],Path(sys.argv[2])
reference=Path('build/verification/offline-player/phase-01/cases')/name/'reference'
data=(out/'board.pcm').read_bytes()
boot=(reference/'boot.pcm').stat().st_size
assert len(data)==boot+(reference/'native.pcm').stat().st_size
results={}
for part,pcm,offset in [('boot',data[:boot],0),('native',data[boot:],boot//8)]:
 path=out/(part+'.pcm');path.write_bytes(pcm)
 results[part]=compare(reference/(part+'.pcm'),path,len(pcm)//8,frame_offset=offset)
results['success']=all(r['success'] for r in results.values())
(out/'digital-comparison.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
print(name,json.dumps(results))
assert results['success']
'@ | py -3 -X utf8 - $name $case
        if ($LASTEXITCODE -ne 0) { throw "Digital mismatch: $name" }
        & (Join-Path $PSScriptRoot 'record_effect_audio.ps1') -Song $song -OutputDirectory $case -Port $Port -AudioDevice $AudioDevice
        & $analysisPython host/compare_effect_audio.py --song $song --output $case --correct-reference-clock
        if ($LASTEXITCODE -ne 0) { throw "Recording comparison failed: $name" }
        Copy-Item -LiteralPath (Join-Path $case "$name-linein.wav") -Destination (Join-Path $delivery "$name.wav") -Force
        Write-Host "SONG_COMPLETE $name"
    }
} finally { $port.Dispose() }
