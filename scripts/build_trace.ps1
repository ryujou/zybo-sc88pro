$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'reference/gearmulator-lock.json') -Raw | ConvertFrom-Json
$upstream = Join-Path $root 'external/gearmulator'
$commit = & git -C $upstream rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit.Trim() -ne $lock.commit) { throw 'Upstream commit differs from lock.' }
$changes = & git -C $upstream status --porcelain
if ($changes) { throw 'Pinned reference is modified.' }
& py -3 -X utf8 (Join-Path $root 'host/prepare_trace.py')
if ($LASTEXITCODE -ne 0) { throw 'Observation overlay generation failed.' }
$build = Join-Path $root 'build/trace'
& cmake -S (Join-Path $root 'host/reference_runner') -B $build -G 'Visual Studio 17 2022' -A x64 -DSC88_BUILD_TRACE=ON
if ($LASTEXITCODE -ne 0) { throw 'Trace configuration failed.' }
& cmake --build $build --config Release --target sc88_register_trace sc88_trace_replay --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Trace build failed.' }
