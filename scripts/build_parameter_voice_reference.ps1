$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'reference/gearmulator-lock.json') -Raw -Encoding utf8 | ConvertFrom-Json
$upstream = Join-Path $root 'external/gearmulator'
$commit = & git -C $upstream rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit.Trim() -ne $lock.commit) { throw 'Upstream commit differs from lock.' }
$changes = & git -C $upstream status --porcelain
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Pinned reference is modified or unavailable.' }
& py -3 -X utf8 (Join-Path $root 'host/prepare_parameter_voice_probe.py')
if ($LASTEXITCODE -ne 0) { throw 'Parameter observation overlay generation failed.' }
$build = Join-Path $root 'build/parameter-voice-reference'
& cmake -S (Join-Path $root 'host/voice_reference') -B $build -G 'Visual Studio 17 2022' -A x64 -DSC88_PARAMETER_OBSERVE=ON
if ($LASTEXITCODE -ne 0) { throw 'Parameter reference configuration failed.' }
& cmake --build $build --config Release --target sc88_voice_vectors sc88_voice_trace_probe sc88_parameter_irq_vectors sc88_multivoice_vectors --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Parameter reference build failed.' }
