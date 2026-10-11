$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'reference/gearmulator-lock.json') -Raw | ConvertFrom-Json
$upstream = Join-Path $root 'external/gearmulator'
$commit = & git -C $upstream rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit.Trim() -ne $lock.commit) { throw 'Upstream commit differs from lock.' }
$changes = & git -C $upstream status --porcelain
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Pinned reference is modified or unavailable.' }
& py -3 -X utf8 (Join-Path $root 'host/prepare_voice_probe.py')
if ($LASTEXITCODE -ne 0) { throw 'Voice observation overlay generation failed.' }
$build = Join-Path $root 'build/voice-reference'
& cmake -S (Join-Path $root 'host/voice_reference') -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Voice reference configuration failed.' }
& cmake --build $build --config Release --target sc88_voice_vectors sc88_voice_trace_probe sc88_ramp_vectors sc88_control_vectors sc88_ramp_service_vectors sc88_source_control_vectors --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Voice reference build failed.' }
