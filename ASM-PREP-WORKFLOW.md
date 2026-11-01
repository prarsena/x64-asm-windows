# Preparing to Write x64 Assembly on Windows: Workflow

A record of the steps taken to prepare this machine for learning assembly. Every
command here can be repeated. The collection script is
[collect-sysinfo.ps1](./collect-sysinfo.ps1).

## 1. Why inspect the machine first?

Assembly is specific to the CPU architecture and the operating system. Before
writing code you need to know:

| Question | Why it matters |
|---|---|
| CPU architecture (x64? ARM64?) | Decides the instruction set and the assembler. x64 assembly will not run on ARM64 natively. |
| Windows bitness and version | Decides the calling convention (Win64) and the available APIs. |
| CPU features (SSE/AVX) | Tells you which instructions you can safely use. |
| Page size and address range | Useful for memory work later. |
| Installed tools | Tells you what to install. |

## 2. Findings for this machine

Collected on 2026-10-29 by running `.\collect-sysinfo.ps1`, which uses several
different Windows APIs. Each row names its source.

| Item | Value | Source |
|---|---|---|
| Computer | Samsung Galaxy Book6 (PRHL) | CIM `Win32_ComputerSystem` |
| CPU | Intel Core Ultra 7 355, 8 cores / 8 logical processors, 64-bit | CIM `Win32_Processor`, registry |
| Architecture | **x64 / AMD64** (code 9) | `kernel32!GetNativeSystemInfo`, `%PROCESSOR_ARCHITECTURE%` |
| CPU family / model / stepping | 6 / 204 / 3 | registry `CentralProcessor\0`, and our own `cpuinfo.exe` via CPUID |
| Clock | ~2.3 GHz base, 3.3 GHz reported by the registry | CIM, registry |
| Cache | L2 16 MB, L3 12 MB | CIM `Win32_Processor` |
| Core layout | Hybrid: 4 P-cores + 4 E-cores (found by `cores.asm`, which pins a thread to each core and asks CPUID) | CPUID leaf 1Ah |
| ISA level | x86-64-v3 (AVX2, no AVX-512) | CPUID, `isalevel.asm` |
| RAM | 15.4 GiB (16,575,762,432 bytes) | `kernel32!GlobalMemoryStatusEx` |
| OS | Windows 11 IoT Enterprise LTSC, build 26100, 64-bit | CIM `Win32_OperatingSystem`, .NET |
| BIOS | AMI PRHL.2.5.19.0 | CIM `Win32_BIOS` |
| Page size | 4096 bytes | `GetNativeSystemInfo` |
| Allocation granularity | 65536 bytes | `GetNativeSystemInfo` |
| User address range | `0x10000` to `0x7FFFFFFEFFFF` (128 TiB) | `GetNativeSystemInfo` |
| SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AES-NI, AVX, AVX2 | supported | `IsProcessorFeaturePresent`, CPUID |
| AVX-512F | **not** supported | `IsProcessorFeaturePresent`, CPUID |
| Shell | PowerShell 7.6 | `$PSVersionTable` |

**Conclusion:** this is a 64-bit Intel x86-64 machine running 64-bit Windows.
The target is therefore **x64 assembly with the Microsoft x64 calling convention**.
Avoid AVX-512 instructions. Everything up to AVX2 is available.

### Cross-checking

The Windows APIs and the CPU itself agree. `cpuinfo.exe`, which executes the
`CPUID` instruction directly, reports the same vendor, brand string,
family/model/stepping and feature flags that the OS reports. It also reports the same
page size and address range from `GetSystemInfo`.

## 3. API reference: where each fact comes from

| Mechanism | What it gave us |
|---|---|
| `kernel32!GetNativeSystemInfo` / `GetSystemInfo` | architecture, page size, address range, processor count |
| `kernel32!IsProcessorFeaturePresent` | OS-confirmed SSE/AVX availability |
| `kernel32!GlobalMemoryStatusEx` | physical and virtual memory |
| CIM/WMI (`Get-CimInstance Win32_*`) | make/model, CPU name, caches, OS build, BIOS |
| Registry `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor` | CPU identifier and MHz |
| .NET `[Environment]` and environment variables | bitness, processor count, `PROCESSOR_*` |
| CPUID instruction (our assembly) | the hardware's own answer, with no OS in between |

`kernel32` functions are called from PowerShell through P/Invoke (`Add-Type`
with `[DllImport]`). Assembly programs call the same functions directly.

## 4. Choosing the toolchain

Nothing was installed at the start: no `nasm`, `ml64`, `link`, `gcc` or `gdb`,
and no Visual Studio. The options were:

| Option | Pros | Cons |
|---|---|---|
| **NASM + MinGW-w64 `ld`/GDB (chosen)** | Small install; one `winget` command; clear Intel syntax; includes a debugger | Not the "official" Microsoft toolchain |
| MASM (`ml64`) + MSVC `link` | Microsoft's own toolchain; integrates with Visual Studio | Needs the multi-GB Visual Studio Build Tools |
| FASM / GoAsm | Self-contained | Smaller community |

Installed with:

```powershell
winget install --id BrechtSanders.WinLibs.POSIX.UCRT --source winget --accept-package-agreements
```

This package provides `nasm` 3.01 (assembler), `ld` / `gcc` (linker), `gdb`
(debugger) and `objdump` (disassembler).

**PATH note:** terminals opened before the install do not see the new PATH. Open a
new terminal, or reload it in the current session:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
```

[build.ps1](./build.ps1) already does this.

## 5. Workflow for each new program

1. **Write** `name.asm` in NASM syntax.
2. **Assemble:** `nasm -f win64 name.asm -o name.obj`. This produces machine code
   in an object file.
3. **Link:** `gcc name.obj -o name.exe -nostartfiles -Wl,-e,main -lkernel32`.
   This produces a Windows `.exe` and resolves the API imports from `kernel32`.
4. **Run:** `.\name.exe`, then check `$LASTEXITCODE`.
5. **Debug if needed:** assemble with `-g`, then use `gdb`.
6. **Inspect:** `objdump -d -M intel name.exe` shows the real machine code.

[build.ps1](./build.ps1) runs steps 2 to 4 (and 5 with `-Gdb`).

## 6. Key Windows x64 rules, learned and verified

These are the rules that cause most beginner crashes. They are verified in
`cpuinfo.asm` and `hello.asm`, and confirmed with GDB (RSP ends in `8` at entry).

- **Arguments:** RCX, RDX, R8, R9, then the stack. Return value in RAX.
- **Shadow space:** the caller reserves 32 bytes above the return address for the callee.
- **Alignment:** RSP must be 16-byte aligned at every `call`. At function entry it is
  8 mod 16, because the return address was just pushed.
- **Volatile registers** (callee may change them): RAX, RCX, RDX, R8 to R11.
- **Non-volatile registers** (callee must preserve them): RBX, RBP, RDI, RSI, R12 to R15.
  Note that `CPUID` overwrites RBX.
- **Writing a 32-bit register zero-extends** into the full 64-bit register.
- Use `default rel` so data is addressed RIP-relative.

## 7. Suggested learning path

1. Run and read `hello.asm`. It makes 3 API calls.
2. Run and read `cpuinfo.asm`. It adds functions, loops, bit manipulation and CPUID.
3. Continue with `isalevel`, `cores`, `topology`, `simd`, `aes` and `galaxybook`
   (see [README.md](./README.md) and [ASM-POWER-AND-VERSIONS.md](./ASM-POWER-AND-VERSIONS.md)).
4. Step through programs in GDB and watch the registers change.
5. Ideas to try next: print the stepping in hex, read `GetTickCount64`, add a
   function that reverses a string, or read command-line arguments with
   `GetCommandLineA`.

## 8. Resources

- Intel SDM (instruction reference)
- Microsoft docs: "x64 calling convention" and "Windows API index"
- NASM manual: https://www.nasm.us/doc/
