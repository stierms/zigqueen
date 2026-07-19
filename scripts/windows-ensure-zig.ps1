param(
    [Parameter(Mandatory = $true)]
    [string]$ToolRoot,

    [string]$Version = "0.15.2"
)

$ErrorActionPreference = "Stop"

$installDir = Join-Path $ToolRoot ("zig-x86_64-windows-" + $Version)
$zigExe = Join-Path $installDir "zig.exe"
if (Test-Path -LiteralPath $zigExe) {
    Write-Output $zigExe
    exit 0
}

New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null

$zipPath = Join-Path $ToolRoot ("zig-x86_64-windows-" + $Version + ".zip")
$url = "https://ziglang.org/download/$Version/zig-x86_64-windows-$Version.zip"

Write-Host ("Downloading Zig " + $Version + " from " + $url)
Invoke-WebRequest -Uri $url -OutFile $zipPath

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -Recurse -Force -LiteralPath $installDir
}

Expand-Archive -Force -LiteralPath $zipPath -DestinationPath $ToolRoot
Remove-Item -Force -LiteralPath $zipPath

if (-not (Test-Path -LiteralPath $zigExe)) {
    throw "zig.exe not found after extraction: $zigExe"
}

Write-Output $zigExe
