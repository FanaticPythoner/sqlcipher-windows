<#
  build-sqlcipher.ps1 – revised 2025-04-25 (Fix "input line is too long" by using vcvarsall.bat)
#>

Param(
    [string]$OpenSslVersion  = '3.3.1',      # https://www.openssl.org/source/
    [string]$SqlCipherBranch = 'v4.5.5',     # tag/commit/branch in sqlcipher repo
    [ValidateSet('x64','Win32')]
    [string]$Architecture    = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$T); Write-Host "`n=== $T ===" -ForegroundColor Cyan }

##############################################################################
# Visual Studio discovery and environment import (using vcvarsall)
##############################################################################
function Get-VsPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio 2022 not found (vswhere.exe missing).' }
    $path = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -version '[17.0,18.0)' -property installationPath |
            Select-Object -First 1 | ForEach-Object { $_.Trim() }
    if (-not $path) { throw 'vswhere returned no installations.' }
    return $path
}

function Import-VsEnv {
    $vsPath = Get-VsPath
    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat not found under $vsPath" }
    # map Architecture to vcvarsall param
    $archArg = if ($Architecture -eq 'x64') { 'amd64' } else { 'x86' }
    # invoke vcvarsall and capture environment
    $cmd = "`"$vcvars`" $archArg && set"
    $envBlock = cmd /c $cmd
    foreach ($line in $envBlock) {
        if ($line -and $line.Contains('=')) {
            $parts = $line -split '=', 2
            Set-Item -Path "Env:$($parts[0])" -Value $parts[1] -Force
        }
    }
}

##############################################################################
# Chocolatey helpers
##############################################################################
function Ensure-ChocoPkg { param([string]$Exe,[string]$Pkg)
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $Pkg …"
        choco install $Pkg -y --no-progress
        $newExe = Get-Command $Exe -ErrorAction SilentlyContinue
        if ($newExe) { $env:Path += ';' + (Split-Path $newExe.Path) }
        else { throw "$Pkg installation succeeded but $Exe not found on PATH." }
    }
}

##############################################################################
# 1 / Prerequisites
##############################################################################
Write-Section 'Validating prerequisites'
Ensure-ChocoPkg 'perl' 'strawberryperl'
Ensure-ChocoPkg 'nasm'  'nasm'
Ensure-ChocoPkg '7z'    '7zip'
Ensure-ChocoPkg 'git'   'git'
Import-VsEnv
$env:CL = '/FS'

##############################################################################
# 2 / Layout
##############################################################################
$Root         = Join-Path $PWD 'sqlcipher-build'
$OpenSslSrc   = Join-Path $Root "openssl-$OpenSslVersion"
$SqlCipherSrc = Join-Path $Root 'sqlcipher'
$BinDir       = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force -Path $Root,$BinDir | Out-Null
$mf           = Join-Path $SqlCipherSrc 'Makefile.msc'

##############################################################################
# 3 / Build OpenSSL
##############################################################################
Write-Section "Downloading OpenSSL $OpenSslVersion"
$Tar = Join-Path $Root "openssl-$OpenSslVersion.tar.gz"
if (-not (Test-Path $Tar)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://www.openssl.org/source/openssl-$OpenSslVersion.tar.gz" -OutFile $Tar
}
if (-not (Test-Path $OpenSslSrc)) {
    Write-Host "Extracting OpenSSL source..."
    & 7z x $Tar    -o"$Root" -aoa | Out-Null
    & 7z x "$Root\openssl-$OpenSslVersion.tar" -o"$Root" -aoa | Out-Null
    Remove-Item "$Root\openssl-$OpenSslVersion.tar"
}
$OpenSslTarget = if ($Architecture -eq 'x64') { 'VC-WIN64A' } else { 'VC-WIN32' }
Write-Section "Building OpenSSL ($OpenSslTarget)"
Push-Location $OpenSslSrc
perl Configure $OpenSslTarget no-tests no-shared --prefix="$OpenSslSrc\out" | Out-Null
nmake clean > $null
nmake; if ($LASTEXITCODE) { throw "OpenSSL build failed (exit $LASTEXITCODE)" }
nmake install_sw
Pop-Location

##############################################################################
# 4 / Fetch SQLCipher
##############################################################################
Write-Section "Cloning SQLCipher ($SqlCipherBranch)"
if (-not (Test-Path $SqlCipherSrc)) {
    git clone --depth 1 --branch $SqlCipherBranch https://github.com/sqlcipher/sqlcipher.git $SqlCipherSrc
}

##############################################################################
# 5 / Build SQLCipher
##############################################################################
Write-Section 'Building SQLCipher'
Push-Location $BinDir

try {
    $TopRel = [System.IO.Path]::GetRelativePath($BinDir, $SqlCipherSrc)
} catch {
    $TopRel = '..\sqlcipher'
}

$env:INCLUDE = "$OpenSslSrc\out\include;$env:INCLUDE"
$env:LIB     = "$OpenSslSrc\out\lib;$env:LIB"

nmake /f $mf `
      TOP=$TopRel `
      USE_CRT_DLL=1 `
      OPTS=' -DSQLITE_HAS_CODEC -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_UNLOCK_NOTIFY ' `
      LTLIBPATHS="/LIBPATH:`"$OpenSslSrc\out\lib`"" `
      LTLIBS="libcrypto.lib libssl.lib" `
      TLIBS="libcrypto.lib libssl.lib ws2_32.lib user32.lib advapi32.lib crypt32.lib kernel32.lib"

if ($LASTEXITCODE) {
    throw "SQLCipher build failed with exit code $LASTEXITCODE"
}
Pop-Location

##############################################################################
# 6 / Finish
##############################################################################
Write-Section 'Done'
Write-Host "Artifacts ready in $BinDir" -ForegroundColor Green
