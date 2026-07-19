param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputName,

    [string]$ToolRoot = "",

    [string]$ZigVersion = "0.15.2",

    [string]$Optimize = "ReleaseFast",

    [string]$Cpu = "",

    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ProjectDir)) {
    throw "Windows build directory not found: $ProjectDir"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}
if (-not $ToolRoot) {
    $ToolRoot = Join-Path $OutputDir "_tools"
}

$ensureScript = Join-Path $PSScriptRoot "windows-ensure-zig.ps1"
$zigExe = & $ensureScript -ToolRoot $ToolRoot -Version $ZigVersion
if (-not (Test-Path -LiteralPath $zigExe)) {
    throw "Resolved zig.exe does not exist: $zigExe"
}

Push-Location -LiteralPath $ProjectDir
try {
    $buildArgs = @("build", "-Doptimize=$Optimize")
    if ($Cpu) {
        $buildArgs += "-Dcpu=$Cpu"
    }
    if ($Version) {
        $buildArgs += "-Dversion=$Version"
    }

    & $zigExe @buildArgs

    $builtExe = Join-Path $ProjectDir "zig-out\bin\zigqueen.exe"
    if (-not (Test-Path -LiteralPath $builtExe)) {
        throw "Built Windows binary not found at $builtExe"
    }

    $outputExe = Join-Path $OutputDir $OutputName
    Copy-Item -Force -LiteralPath $builtExe -Destination $outputExe
    Write-Host ("Copied zigqueen.exe to " + $outputExe)
}
finally {
    Pop-Location
}
