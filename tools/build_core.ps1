# Builds the native core standalone and runs its ctest suites.
#
# The Flutter app builds the same CMake target through windows/CMakeLists.txt;
# this script exists so the core can be compiled and tested without Flutter,
# which is what the migration requires for every phase.
#
# Usage:
#   pwsh -File tools/build_core.ps1                 # Debug build + tests
#   pwsh -File tools/build_core.ps1 -Config Release
#   pwsh -File tools/build_core.ps1 -Clean
param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string]$Config = 'Debug',
    [string]$BuildDir = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    if (-not $BuildDir) {
        $BuildDir = Join-Path 'build' 'native' 'videoder_core'
    }
    if ($Clean -and (Test-Path -LiteralPath $BuildDir)) {
        # Never delete anything outside this checkout.
        $resolved = (Resolve-Path -LiteralPath $BuildDir).Path
        if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "refusing to clean '$resolved': it is outside $root"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    $configure = @(
        '-S', (Join-Path $root 'native' 'videoder_core'),
        '-B', $BuildDir,
        "-DCMAKE_BUILD_TYPE=$Config"
    )
    if (Get-Command ninja -ErrorAction SilentlyContinue) {
        $configure += @('-G', 'Ninja')
    }

    Write-Host "Configuring videoder_core ($Config)..."
    & cmake @configure
    if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }

    Write-Host 'Building videoder_core...'
    & cmake --build $BuildDir
    if ($LASTEXITCODE -ne 0) { throw 'cmake build failed' }

    Write-Host 'Running native core tests...'
    & ctest --test-dir $BuildDir --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'native core tests failed' }

    $library = Get-ChildItem -LiteralPath $BuildDir -Filter 'videoder_core.*' -File |
        Where-Object { $_.Extension -in '.dll', '.so', '.dylib' } |
        Select-Object -First 1
    if ($library) {
        Write-Host "Built: $($library.FullName)"
        Write-Host 'Dart picks it up automatically, or set VIDEODER_CORE_LIBRARY to force it.'
    }
} finally {
    Pop-Location
}
