<#
.SYNOPSIS
  Assemble, link and (optionally) run a NASM x64 program.
.EXAMPLE
  .\build.ps1 hello -Run
  .\build.ps1 cpuinfo -Run
  .\build.ps1 hello -Gdb        # includes debug symbols and opens GDB
#>
param(
  [Parameter(Mandatory)][string]$Name,   # file name without .asm
  [switch]$Run,
  [switch]$Gdb
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# A terminal opened before the install has a stale PATH, so reload it.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$nasmArgs = @('-f', 'win64', "$Name.asm", '-o', "$Name.obj")
if ($Gdb) { $nasmArgs += @('-g') }   # -g adds debug symbols
nasm @nasmArgs
if ($LASTEXITCODE) { throw 'nasm failed' }

# gcc is used only as a linker driver. -nostartfiles skips the C runtime, so
# our own 'main' label is the real process entry point (-e main).
gcc "$Name.obj" -o "$Name.exe" -nostartfiles '-Wl,-e,main' -lkernel32 -luser32 -ladvapi32
if ($LASTEXITCODE) { throw 'link failed' }
Write-Host "Built $Name.exe"

if ($Gdb) { gdb ".\$Name.exe" }
elseif ($Run) { & ".\$Name.exe"; Write-Host "(exit code $LASTEXITCODE)" }
