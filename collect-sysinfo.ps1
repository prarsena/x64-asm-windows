<#
.SYNOPSIS
  Collects the hardware/OS facts that matter before writing x64 assembly on Windows.
  Each section names the Windows API (or provider) it comes from.
#>

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Native {
  [StructLayout(LayoutKind.Sequential)] public struct SYSTEM_INFO {
    public ushort wProcessorArchitecture, wReserved; public uint dwPageSize;
    public IntPtr lpMinimumApplicationAddress, lpMaximumApplicationAddress, dwActiveProcessorMask;
    public uint dwNumberOfProcessors, dwProcessorType, dwAllocationGranularity;
    public ushort wProcessorLevel, wProcessorRevision;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MEMORYSTATUSEX {
    public uint dwLength, dwMemoryLoad;
    public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
  }
  [DllImport("kernel32.dll")] public static extern void GetNativeSystemInfo(out SYSTEM_INFO si);
  [DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);
  [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
  [DllImport("kernel32.dll")] public static extern uint GetACP();
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
}
'@

function Section($t) { "`n=== $t ===" }

Section 'kernel32!GetNativeSystemInfo'
$si = New-Object Native+SYSTEM_INFO
[Native]::GetNativeSystemInfo([ref]$si)
"Architecture code      : $($si.wProcessorArchitecture)  (9 = x64, 12 = ARM64)"
"Page size              : $($si.dwPageSize) bytes"
"Allocation granularity : $($si.dwAllocationGranularity) bytes"
"Min / max user address : 0x{0:X} / 0x{1:X}" -f [int64]$si.lpMinimumApplicationAddress, [int64]$si.lpMaximumApplicationAddress
"Logical processors     : $($si.dwNumberOfProcessors)"
"Processor level/rev    : $($si.wProcessorLevel) / 0x$($si.wProcessorRevision.ToString('X4'))"

Section 'kernel32!IsProcessorFeaturePresent'
# PF_* constants from winnt.h
$features = [ordered]@{
  PF_XMMI64_INSTRUCTIONS_AVAILABLE = 10   # SSE2
  PF_SSE3_INSTRUCTIONS_AVAILABLE   = 13
  PF_SSSE3_INSTRUCTIONS_AVAILABLE  = 36
  PF_SSE4_1_INSTRUCTIONS_AVAILABLE = 37
  PF_SSE4_2_INSTRUCTIONS_AVAILABLE = 38
  PF_AVX_INSTRUCTIONS_AVAILABLE    = 39
  PF_AVX2_INSTRUCTIONS_AVAILABLE   = 40
  PF_AVX512F_INSTRUCTIONS_AVAILABLE = 41
}
foreach ($k in $features.Keys) { '{0,-36} {1}' -f $k, [Native]::IsProcessorFeaturePresent($features[$k]) }

Section 'kernel32!GlobalMemoryStatusEx'
$m = New-Object Native+MEMORYSTATUSEX
$m.dwLength = [Runtime.InteropServices.Marshal]::SizeOf($m)
[void][Native]::GlobalMemoryStatusEx([ref]$m)
"Physical RAM total     : {0:N0} bytes ({1:N1} GiB)" -f $m.ullTotalPhys, ($m.ullTotalPhys / 1GB)
"Virtual address space  : {0:X} bytes" -f $m.ullTotalVirtual
"Memory load            : $($m.dwMemoryLoad)%"

Section 'WMI/CIM (Win32_ComputerSystem, Win32_Processor, Win32_OperatingSystem, Win32_BIOS)'
Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, SystemType
Get-CimInstance Win32_Processor | Format-List Name, Manufacturer, Architecture, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, AddressWidth, L2CacheSize, L3CacheSize
Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, OSArchitecture
Get-CimInstance Win32_BIOS | Format-List Manufacturer, SMBIOSBIOSVersion

Section 'Registry (HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0)'
$cpuKey = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
foreach ($v in 'ProcessorNameString', 'Identifier', 'VendorIdentifier', '~MHz') {
  '{0,-20} : {1}' -f $v, (Get-ItemPropertyValue $cpuKey -Name $v)
}

Section '.NET / environment'
"Is64BitOperatingSystem : $([Environment]::Is64BitOperatingSystem)"
"Is64BitProcess         : $([Environment]::Is64BitProcess)"
"ProcessorCount         : $([Environment]::ProcessorCount)"
"PROCESSOR_ARCHITECTURE : $env:PROCESSOR_ARCHITECTURE"
"PROCESSOR_IDENTIFIER   : $env:PROCESSOR_IDENTIFIER"
"OS version             : $([Environment]::OSVersion.VersionString)"
"ANSI code page         : $([Native]::GetACP())"
"PowerShell             : $($PSVersionTable.PSVersion)"

Section 'Toolchain on PATH'
foreach ($t in 'nasm', 'ld', 'gcc', 'gdb', 'objdump', 'ml64', 'link') {
  $c = Get-Command $t -ErrorAction SilentlyContinue
  '{0,-8} {1}' -f $t, $(if ($c) { $c.Source } else { '(not found)' })
}
