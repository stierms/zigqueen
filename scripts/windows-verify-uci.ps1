param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "Windows executable not found: $ExePath"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ExePath
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false

$process = [System.Diagnostics.Process]::Start($psi)
$process.StandardInput.WriteLine("uci")
$process.StandardInput.WriteLine("quit")
$process.StandardInput.Close()

$output = $process.StandardOutput.ReadToEnd()
$process.WaitForExit()
Write-Output $output

if ($output -notmatch "id name zigqueen") {
    throw "UCI probe did not report zigqueen identity"
}
if ($output -notmatch "uciok") {
    throw "UCI probe did not reach uciok"
}
