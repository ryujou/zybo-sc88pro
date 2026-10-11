param(
    [Parameter(Mandatory=$true)][string]$CableSerial,
    [Parameter(Mandatory=$true)][string]$Port
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
$phase=Join-Path $root 'build/verification/offline-player/phase-04'
$out=Join-Path $phase 'hardware/current-seven-songs'
[void][System.IO.Directory]::CreateDirectory($out)
$utf8=[System.Text.UTF8Encoding]::new($false)
$report=@{scope='USB_parameter_seven_song_playback_and_digital_windows';success=$false;hardware_verified=$false;phase4_gate_passed=$false;full_effects_verified=$false;songs=@()}
$portHandle=$null
$loaded=$false
function Command-Status([string]$Key,[int]$Timeout=5) {
    $portHandle.Write($Key)
    $response=[System.Text.StringBuilder]::new()
    $timer=[System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Timeout) {
        [void]$response.Append($portHandle.ReadExisting())
        if ($response.ToString() -match "(SC88 key=$Key [^\r\n]+)\r?\n") {
            $line=$Matches[1]
            $values=@{}
            foreach ($field in [regex]::Matches($line,'(\w+)=([^ ]+)')) {$values[$field.Groups[1].Value]=$field.Groups[2].Value}
            foreach ($name in @('rc','playing','result','frames','pl_fault','ps_fault','fifo','max_due','callback_us','service_us','gap_us','usb_faults','retry_fail')) {
                if (!$values.ContainsKey($name)) {throw "Incomplete UART status: $line"}
            }
            if ([int]$values.rc -ne 0) {throw "Command failed: $line"}
            [System.IO.File]::AppendAllText((Join-Path $out 'uart.log'),$line+"`n",$utf8)
            return $values
        }
        Start-Sleep -Milliseconds 20
    }
    throw "UART timeout for key=$Key : $response"
}
function Assert-Playback($Status) {
    if ($Status.pl_fault -ne '00000000' -or [int]$Status.ps_fault -ne 0 -or [int]$Status.usb_faults -ne 0 -or [int]$Status.retry_fail -ne 0) {throw 'Playback or storage fault; see uart.log'}
    if ([int]$Status.max_due -gt 3125 -or [int]$Status.callback_us -ge 500 -or [int]$Status.service_us -ge 500 -or [int]$Status.gap_us -ge 500) {throw 'Playback deadline exceeded; see uart.log'}
}
try {
    [System.IO.File]::WriteAllText((Join-Path $out 'summary.json'),($report | ConvertTo-Json -Depth 5),$utf8)
    [System.IO.File]::WriteAllText((Join-Path $out 'uart.log'),'',$utf8)
    $firmware=Get-Content -LiteralPath (Join-Path $phase 'parameter-capture-ps/summary.json') -Raw -Encoding utf8 | ConvertFrom-Json
    if (!$firmware.success -or $firmware.capture.first_frame -ne 352000 -or $firmware.capture.frames -ne 2048 -or $firmware.capture.words_per_frame -ne 323) {throw 'Build the current capture ELF with --capture-first 352000'}
    $symbols=Get-Content -LiteralPath (Join-Path $phase 'parameter-capture-ps/symbols.log') -Raw -Encoding utf8
    $symbol=[regex]::Match($symbols,'(?m)^([0-9a-fA-F]+) [Bb] sc88_parameter_capture_frames\r?$')
    if (!$symbol.Success) {throw 'Capture counter symbol is missing'}
    $counter='0x'+$symbol.Groups[1].Value
    $portHandle=[System.IO.Ports.SerialPort]::new($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
    $portHandle.Open()
    $portHandle.DiscardInBuffer()
    $load=(& py -3 -X utf8 host/parameter_jtag.py --capture --load --cable-serial $CableSerial | Out-String)
    [System.IO.File]::WriteAllText((Join-Path $out 'jtag-load.log'),$load,$utf8)
    if ($LASTEXITCODE -ne 0 -or $load -notmatch 'SC88_PARAMETER_JTAG_STARTED') {throw 'Paired capture JTAG load failed'}
    $loaded=$true
    $startup=[System.Text.StringBuilder]::new()
    $timer=[System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 10 -and $startup.ToString() -notmatch 'SC88_PARAMETER_DIAGNOSTIC.*cells=8,9') {
        [void]$startup.Append($portHandle.ReadExisting())
        Start-Sleep -Milliseconds 20
    }
    if ($startup.ToString() -notmatch 'SC88_PARAMETER_DIAGNOSTIC.*cells=8,9') {throw "Missing capture startup: $startup"}
    [System.IO.File]::WriteAllText((Join-Path $out 'startup.log'),$startup.ToString(),$utf8)
    $status=Command-Status 'h'
    $timer.Restart()
    while ([int]$status.device -eq 0) {
        if ($timer.Elapsed.TotalSeconds -ge 10) {throw 'USB enumeration timed out'}
        Start-Sleep -Milliseconds 100
        $status=Command-Status 's'
    }
    $timer.Restart()
    $status=Command-Status 'w' 45
    Assert-Playback $status
    $report.wave_load_ms=$timer.ElapsedMilliseconds
    $report.usb_sector_bytes=[int]$status.sector
    $report.usb_sectors=[long]$status.sectors
    foreach ($song in 1..7) {
        $name='th06_{0:00}' -f $song
        $baseline=Get-Content -LiteralPath (Join-Path $root "build/verification/th06-midi/$name/result.json") -Raw -Encoding utf8 | ConvertFrom-Json
        if ($baseline.status -ne '通过') {throw "Software baseline is not accepted: $name"}
        $frames=[long]$baseline.boot_frames+[long]$baseline.case_frames
        $status=Command-Status ([string]$song) 45
        $timer.Restart()
        do {
            Start-Sleep -Milliseconds 1000
            $status=Command-Status 's'
            Assert-Playback $status
            if ($timer.Elapsed.TotalSeconds -gt $frames/32000+30) {throw "$name playback timed out"}
        } while ([int]$status.playing -ne 0)
        if ([int]$status.result -ne 1 -or [long]$status.frames -ne $frames -or [int]$status.fifo -ne 0) {throw "$name did not finish all frames and drain I2S"}
        $seconds=$timer.Elapsed.TotalSeconds
        $capture=(Join-Path $out "$name.bin").Replace('\','/')
        $script=@"
connect -url tcp:127.0.0.1:3121
targets -set -filter {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "$CableSerial"}
stop
set count [lindex [mrd -value $counter] 0]
if {`$count != 2048} {error "Incomplete capture: `$count"}
mrd -bin -file {$capture} 0x08000000 1323008
con
puts "SC88_RESULT_CAPTURE_DUMP_COMPLETE"
disconnect
"@
        $tcl=Join-Path $out "$name-dump.tcl"
        [System.IO.File]::WriteAllText($tcl,$script,$utf8)
        $dump=(& (Join-Path $env:VITIS_ROOT 'bin/xsct.bat') $tcl | Out-String)
        [System.IO.File]::WriteAllText((Join-Path $out "$name-dump.log"),$dump,$utf8)
        if ($LASTEXITCODE -ne 0 -or $dump -notmatch 'SC88_RESULT_CAPTURE_DUMP_COMPLETE') {throw "$name JTAG dump failed"}
        & py -3 -X utf8 host/check_parameter_capture.py $capture --reference (Join-Path $phase "hardware/golden/$name")
        if ($LASTEXITCODE -ne 0) {throw "$name digital comparison failed"}
        $report.songs+=@{song=$name;total_frames=$frames;playback_seconds=$seconds;status=$status;capture_first_frame=352000;capture_frames=2048;records=655360;channel_samples=4096;digital_errors=0}
        Write-Output "$name full dry playback finished: frames=$frames callback_us=$($status.callback_us) max_due=$($status.max_due); captured digital window exact"
    }
    $report.success=$true
    $report.hardware_verified=$true
} catch {
    $report.error=$_.Exception.Message
    throw
} finally {
    if ($null -ne $portHandle) {
        if ($loaded -and $portHandle.IsOpen) {$portHandle.Write('x')}
        $portHandle.Dispose()
    }
    [System.IO.File]::WriteAllText((Join-Path $out 'summary.json'),($report | ConvertTo-Json -Depth 5),$utf8)
}
