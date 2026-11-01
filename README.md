# Running Assembly Programs on Windows

Programs (x64 NASM, Windows):

| File | What it shows | Run |
|---|---|---|
| [hello.asm](./hello.asm) | Minimal program: prints a message through the Windows API | `.\build.ps1 hello -Run` |
| [cpuinfo.asm](./cpuinfo.asm) | CPUID instruction, bit tests, functions, `GetSystemInfo` | `.\build.ps1 cpuinfo -Run` |
| [isalevel.asm](./isalevel.asm) | Which x86-64 level (v1 to v4) the CPU supports; table-driven CPUID; `XGETBV` | `.\build.ps1 isalevel -Run` |
| [topology.asm](./topology.asm) | Cache sizes, TSC clock, address widths; `RDTSC` timing | `.\build.ps1 topology -Run` |
| [cores.asm](./cores.asm) | Per-core detection of P-cores and E-cores by pinning the thread | `.\build.ps1 cores -Run` |
| [simd.asm](./simd.asm) | Scalar vs SSE2 vs AVX2 benchmark with verified results | `.\build.ps1 simd -Run` |
| [aes.asm](./aes.asm) | AES-128 with AES-NI (FIPS-197 test vector) and `RDRAND` | `.\build.ps1 aes -Run` |
| [galaxybook.asm](./galaxybook.asm) | Samsung firmware (SMBIOS), registry, battery, display, RAM | `.\build.ps1 galaxybook -Run` |
| [common.inc](./common.inc) | Shared print and CPUID helper routines (included by the programs above except `hello` and `cpuinfo`) | not run directly |

Supporting files: [collect-sysinfo.ps1](./collect-sysinfo.ps1) (system facts),
[samsung-probe.ps1](./samsung-probe.ps1) (read-only Samsung discovery),
[c-comparison/](./c-comparison) (C source and the assembly GCC generates from it).

For how this machine was assessed and the toolchain chosen, see
[ASM-PREP-WORKFLOW.md](./ASM-PREP-WORKFLOW.md). For what assembly can do, how the
"version" and C relate, and the Samsung findings, see
[ASM-POWER-AND-VERSIONS.md](./ASM-POWER-AND-VERSIONS.md).

Suggested order: `hello`, `cpuinfo`, `isalevel`, `cores`, `topology`, `simd`, `aes`, `galaxybook`.

## Prerequisites (one time)

```powershell
winget install --id BrechtSanders.WinLibs.POSIX.UCRT --source winget
```

Then open a **new** terminal so PATH updates. Check with `nasm -v` and `ld --version`.

## Quick way

From this folder in PowerShell:

```powershell
.\build.ps1 hello -Run
.\build.ps1 cpuinfo -Run
```

If scripts are blocked, run this once for the current session:
`Set-ExecutionPolicy -Scope Process Bypass`

## Manual way (what the script does)

```powershell
# 1. Assemble: NASM source -> 64-bit Windows object file
nasm -f win64 hello.asm -o hello.obj

# 2. Link: object file -> hello.exe
#    -nostartfiles   don't add the C runtime startup code
#    -Wl,-e,main     our 'main' label is the entry point
#    -lkernel32      import GetStdHandle, WriteFile, ExitProcess
gcc hello.obj -o hello.exe -nostartfiles -Wl,-e,main -lkernel32

# 3. Run and check the exit code
.\hello.exe
$LASTEXITCODE        # 0
```

Replace `hello` with any program name to build it. Programs that use more Windows DLLs
need more libraries at link time, so `build.ps1` always passes
`-lkernel32 -luser32 -ladvapi32` (the linker only imports what the program uses):

```powershell
gcc galaxybook.obj -o galaxybook.exe -nostartfiles -Wl,-e,main -lkernel32 -luser32 -ladvapi32
```

## Expected output

`hello.exe`:

```
Hello from x64 assembly on Windows!
```

`cpuinfo.exe` (on this machine):

```
=== cpuinfo.asm : CPUID + GetSystemInfo ===

Vendor string        : GenuineIntel
Brand string         : Intel(R) Core(TM) Ultra 7 355
Max basic CPUID leaf : 36
Family               : 6
Model                : 204
Stepping             : 3

CPU feature flags (from CPUID):
  SSE2     : yes
  ...
  AVX2     : yes
  AVX-512F : no

GetSystemInfo (Windows API):
  Architecture code  : 9
  Page size (bytes)  : 4096
  ...
```

On a different CPU the values will differ. That is the point of the program.

## Debugging with GDB

```powershell
.\build.ps1 cpuinfo -Gdb        # assembles with -g, links, opens gdb
```

Useful commands at the `(gdb)` prompt:

```
set disassembly-flavor intel    # show Intel syntax like the source
break main                      # stop at the entry point
run
stepi                           # execute one instruction (alias: si)
info registers                  # all registers (or: info registers rax rcx)
x/6i $rip                       # disassemble next 6 instructions
x/s &vendor                     # show a string in memory
continue
quit
```

Or from a script, without interacting:

```powershell
gdb -q -batch -ex "break main" -ex "run" -ex "info registers rsp" .\hello.exe
```

## Disassemble the result

```powershell
objdump -d -M intel hello.exe
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `nasm` is not recognized | Open a new terminal, or run the PATH reload line in the workflow doc. |
| `undefined reference to 'GetStdHandle'` | Missing `-lkernel32` at link time (user32/advapi32 are needed for display and registry APIs). |
| Crash inside an API call | Check RSP 16-byte alignment and that 32 bytes of shadow space were reserved. |
| Crash after `cpuid` | RBX was not preserved. Save and restore it. |
| Wrong address or segfault reading data | Missing `default rel` at the top of the file. |
| `.obj` built but `.exe` won't link | Make sure you assemble with `-f win64` (not `win32`). |
