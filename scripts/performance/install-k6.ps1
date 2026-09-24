$ErrorActionPreference = 'Stop'
# Pinned official binary; verify before extracting/executing. Installs only in the workspace.
$rcRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$rcTools = Join-Path $rcRoot '.runtime/performance/tools'
New-Item -ItemType Directory -Path $rcTools -Force | Out-Null
$rcZip = Join-Path $rcTools 'k6-v2.2.0-windows-amd64.zip'
if (-not (Test-Path -LiteralPath $rcZip)) {
  Invoke-WebRequest -Uri 'https://github.com/grafana/k6/releases/download/v2.2.0/k6-v2.2.0-windows-amd64.zip' -OutFile $rcZip -UseBasicParsing
}
$rcExpectedHash = 'ceb2b1e1cf9dbe1303c6c33ec83ffda86dda5c610b4def92064d3c7ebae8d9f4'
if ((Get-FileHash -LiteralPath $rcZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rcExpectedHash) { throw 'k6 checksum mismatch' }
Expand-Archive -LiteralPath $rcZip -DestinationPath $rcTools -Force
& (Join-Path $rcTools 'k6-v2.2.0-windows-amd64/k6.exe') version
