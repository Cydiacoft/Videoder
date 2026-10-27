param([string]$ReleaseDirectory = "build/windows/x64/runner/Release")
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$releasePath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $ReleaseDirectory))
foreach ($required in @("videoder_demo.exe", "videoder_core.dll", "data/flutter_assets/assets/extensions/generated/index.json", "data/flutter_assets/assets/extensions/generated/yt-dlp.vdx", "data/flutter_assets/assets/extensions/generated/tiktok-downloader.vdx")) {
    if (-not (Test-Path -LiteralPath (Join-Path $releasePath $required))) {
        throw "Release is incomplete: $required"
    }
}
$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot "pubspec.yaml") -Pattern '^version:\s*(\S+)'
$version = $versionMatch.Matches[0].Groups[1].Value
$distPath = Join-Path $projectRoot "dist"
New-Item -ItemType Directory -Path $distPath -Force | Out-Null
$archivePath = Join-Path $distPath "Videoder-v$version-windows-x64.zip"
Compress-Archive -Path (Join-Path $releasePath "*") -DestinationPath $archivePath -Force
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$archivePath.sha256" -Value "$hash  $([System.IO.Path]::GetFileName($archivePath))"
Write-Output $archivePath
Write-Output "SHA256: $hash"
