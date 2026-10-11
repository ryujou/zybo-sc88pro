param([switch]$Slices, [ValidateRange(1,7)][int]$Song = 1, [string]$OutputDirectory = '',
    [Parameter(Mandatory=$true)][string]$Port, [Parameter(Mandatory=$true)][string]$AudioDevice)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $root 'build/verification/offline-player/effects/recording' }
$songName = 'th06_{0:00}' -f $Song
$nativeFrames = (Get-Item (Join-Path $root "build/verification/offline-player/phase-01/cases/$songName/reference/native.pcm")).Length / 8
New-Item -ItemType Directory -Force -Path $output | Out-Null
$port = [System.IO.Ports.SerialPort]::new($Port, 115200)
$port.Open()
try {
    $keys = if ($Slices) { @('a', 'b', 'c') } else { @('p') }
    foreach ($slice in $keys) {
        $port.DiscardInBuffer()
        $start = [System.Diagnostics.ProcessStartInfo]::new('ffmpeg')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $seconds = if ($slice -eq 'p') { [int][Math]::Ceiling($nativeFrames / 32000) + 4 } elseif ($slice -eq 'c') { [int][Math]::Ceiling([Math]::Min(30.1, $nativeFrames / 32000 - 59.9)) + 4 } else { 34 }
        foreach ($argument in @('-hide_banner', '-y', '-f', 'dshow', '-sample_rate', '44100',
            '-channels', '2', '-i', "audio=$AudioDevice",
            '-t', "$seconds", '-c:a', 'pcm_s16le', (Join-Path $output "slice-$slice.wav"))) {
            $start.ArgumentList.Add($argument)
        }
        $capture = [System.Diagnostics.Process]::Start($start)
        $captureLog = $capture.StandardError.ReadToEndAsync()
        try {
            Start-Sleep -Seconds 1
            if ($capture.HasExited) { throw "Recording failed before slice $slice started." }
            $port.Write($slice)
            $status = ''
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            while (!$capture.HasExited -and $timer.Elapsed.TotalSeconds -lt $seconds + 5) {
                $status += $port.ReadExisting()
                Start-Sleep -Milliseconds 100
            }
            $status += $port.ReadExisting()
            if (!$capture.HasExited) { throw "Recording timeout for slice $slice." }
            $captureLog.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $output "slice-$slice-ffmpeg.log") -Encoding utf8
            $status | Set-Content -LiteralPath (Join-Path $output "slice-$slice-uart.log") -Encoding utf8
            if ($capture.ExitCode -ne 0 -or $status -notmatch "key=$slice rc=0 " -or
                $status -notmatch 'pl_fault=00000000') { throw "Slice $slice failed; inspect recording and UART logs." }
            if ($slice -eq 'p' -and $status -notmatch "audio_frames=$nativeFrames pl_fault=00000000 ps_fault=0 fifo=0") { throw 'Incomplete whole-song playback.' }
            Write-Output "Recorded slice $slice."
        } finally {
            if (!$capture.HasExited) { $capture.Kill(); $capture.WaitForExit() }
            $capture.Dispose()
        }
    }
} finally {
    $port.Close()
}
