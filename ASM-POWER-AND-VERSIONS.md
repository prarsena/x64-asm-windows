# What Assembly Can Do, Which "Version" You Have, and What Your Galaxy Book Exposes

Companion to [ASM-PREP-WORKFLOW.md](./ASM-PREP-WORKFLOW.md) and [README.md](./README.md).
Everything below was measured on this machine (Samsung Galaxy Book6, Intel Core Ultra 7 355).

## 1. The power of assembly

Assembly is the human-readable form of the instructions the CPU runs. Each line is
one machine instruction (or very close to it), so you control exactly what the
processor does. That gives you:

| Power | Why | Demonstrated in |
|---|---|---|
| **Use any instruction the CPU has** | Compilers target a conservative baseline by default and may never emit special instructions. | [aes.asm](./aes.asm) (AES-NI, RDRAND), [simd.asm](./simd.asm) (SSE2/AVX2) |
| **Ask the hardware itself** | `CPUID`, `RDTSC` and `XGETBV` answer directly, with no OS in between. | [isalevel.asm](./isalevel.asm), [topology.asm](./topology.asm), [cores.asm](./cores.asm) |
| **Full control of data layout and calls** | You choose registers, stack layout, struct offsets, and how Windows APIs are called. | [galaxybook.asm](./galaxybook.asm) (SMBIOS parsing, 7-argument API call) |
| **Tiny, dependency-free programs** | No C runtime. `hello.exe` is 6 KB. | [hello.asm](./hello.asm) |
| **Understanding** | Debuggers, malware analysis, compilers, OS kernels and reverse engineering all speak assembly. | GDB steps in the README |

### Measured on this machine

| Program | Result |
|---|---|
| `simd` | Summing 32,768 ints x 20,000: **scalar 182 ms, SSE2 46 ms (3.9x), AVX2 33 ms (5.5x)**. All results verified. AVX2 is limited by cache bandwidth here, because the 128 KiB array is larger than the 48 KiB L1. |
| `aes` | Reproduces the official FIPS-197 AES-128 test vector exactly (`69C4E0D8...C55A`) and decrypts it back, using the CPU's AES circuits. |
| `cores` | **Hybrid CPU: 4 P-cores + 4 E-cores.** P-cores each have 3 MiB L2 and see the 12 MiB L3. The E-cores share a 4 MiB L2 and see no L3. 4x3 + 4 = **16 MiB L2**, which matches the 16384 KB Windows WMI reports. |
| `topology` | L1d 48 KiB, L1i 64 KiB, 46-bit physical / 48-bit virtual addresses. TSC = 38.4 MHz crystal x 172 / 2 = **3302 MHz**, confirmed by timing against `QueryPerformanceCounter` (3302 MHz) and the registry (`~MHz` 3302). |

### What assembly can NOT easily do

- **Privileged instructions fault in user mode.** `RDMSR`, `IN`/`OUT`, `CLI`, `HLT` and
  control-register access require ring 0, so they need a kernel driver.
- **It is not portable.** This code is x86-64 Windows only. ARM64 or Linux need rewrites.
- **It is slow to write and easy to get wrong.** For most programs a compiler with
  `-O2` produces code as good as a human (see section 3). Assembly pays off for
  small hot loops, special instructions, boot code and firmware.

## 2. "What version of ASM is running here?"

There is no single version. Three different things get called "the version":

| Layer | What it is | On this machine |
|---|---|---|
| **Instruction set** (what the CPU understands) | x86-64 plus extensions, grouped into levels v1 to v4 | **x86-64-v3** (AVX2, BMI1/2, FMA, ...). No AVX-512, so not v4. Also has AES-NI, SHA, RDSEED, VAES, AVX-VNNI. See `isalevel`. |
| **Assembler** (the program that turns text into machine code) | NASM, MASM, GNU `as`, FASM... each has its own *syntax* | **NASM 3.01** (Intel syntax). Also GNU `as` 2.47 (inside the GCC toolchain). |
| **Assembly syntax dialect** | Intel syntax (`mov eax, [rbx]`) vs AT&T syntax (`movl (%rbx), %eax`) | We write Intel syntax. GDB shows AT&T by default (`set disassembly-flavor intel` changes it). |

The CPU generation is visible too: CPUID family 6, model 204 (0xCC). The firmware SKU string
is `PRHL-760XJG-PTLH-0`, and `PTLH` looks like Intel's **Panther Lake-H**
(an inference from the name, not confirmed by Intel documentation).

## 3. Is it related to the version of C installed?

**Not directly.** NASM is an independent program and has no dependency on any C compiler.
But the two are closely related, because **a C compiler produces assembly and then runs an assembler**:

```
C source --gcc (cc1)--> assembly text (.s) --as--> object (.o) --ld--> program (.exe)
                                                    ^
NASM source (.asm) ---------nasm--------> object (.obj) -----+   (same linker, same object format)
```

Installed on this machine (from WinLibs):

| Tool | Version |
|---|---|
| GCC (C compiler) | 16.2.0, target `x86_64-w64-mingw32` |
| GNU assembler `as` | 2.47 (binutils) |
| GNU linker `ld` | 2.47 |
| NASM | 3.01 |
| MSVC / `ml64` | not installed |

Our `build.ps1` uses `nasm` to assemble and `gcc` purely as a **linker driver**. NASM's
`.obj` and GCC's `.o` are the same kind of file, which is why they link together, and why
you can mix assembly functions with C code.

### See the connection yourself

[c-comparison/sum.c](./c-comparison/sum.c) is a four-line C function. GCC can show you the
assembly it generates (`gcc -S -masm=intel`):

```
; gcc -O2  (sum_O2.s)  - essentially our hand-written scalar loop in simd.asm
.L3:
    add   eax, DWORD PTR [rcx]
    add   rcx, 4
    cmp   rcx, rdx
    jne   .L3
```

```
; gcc -O3 -mavx2  (sum_O3_avx2.s)  - the compiler now emits the same AVX2 instruction we used
    vpaddd  ymm0, ymm0, YMMWORD PTR [rax]
```

Two lessons:

1. **GCC defaults to the baseline CPU (x86-64-v1)**, so by default it will not use AVX2 even though this
   CPU has it. Add `-march=x86-64-v3` (or `-march=native`) to let it.
2. Compilers are good. The assembly in `simd.asm` is faster than GCC's loop mainly because it
   uses four independent accumulators and hand-picked instructions.

Reproduce:

```powershell
cd c-comparison
gcc -O2 -S -masm=intel sum.c -o sum_O2.s
gcc -O3 -mavx2 -S -masm=intel sum.c -o sum_O3_avx2.s
```

## 4. Samsung-specific interfaces on this laptop

A read-only survey is in [samsung-probe.ps1](./samsung-probe.ps1).

### What is exposed

| Interface | Details | Usable from assembly? |
|---|---|---|
| **SMBIOS firmware tables** | Samsung's BIOS (AMI, `PRHL.2.5.19.0`, SMBIOS 3.8) stores model, family, SKU and board data. | **Yes, no admin needed.** [galaxybook.asm](./galaxybook.asm) parses them with `GetSystemFirmwareTable('RSMB')`. |
| **Registry BIOS keys** | `HKLM\HARDWARE\DESCRIPTION\System\BIOS` mirrors SMBIOS strings. | **Yes**, `RegGetValueA`. |
| **Standard Windows APIs** | Battery (`GetSystemPowerStatus`), display mode, installed RAM. | **Yes**, all in `galaxybook.asm`. |
| **WMI namespace `root\Samsung`** | One class, `BiosManager` ("Samsung BIOS setup manager"), with methods `Get`, `Set`, `Save`, `SetPassword`, `EnumSetting`, `LoadDefault`, `SetDefault`, `GetString`, `GetRevision`. | Possible via COM, but **admin is required** (access is denied for normal users) and the methods can **modify firmware settings and set BIOS passwords**. I did not call any of them. |
| **ACPI device `SAM0430`** | "Samsung System Event Controller" (driver 1.1.0.6): handles firmware events such as hotkeys. | Only through Samsung's driver, whose interface is undocumented. |
| **Samsung System Support Service** | Driver-store service (`SamsungSystemSupportService`, v8.0.13.0), which likely bridges the Samsung apps to the firmware. | Undocumented. |
| **Samsung apps and services** | About 27 Store apps (Samsung Settings, Quick Share, Multi Control, Second Screen, Samsung Notes, PC Diagnostics, Galaxy Buds, ...) and about 15 services. | They talk to the services above. No public developer API was found on the machine. |
| **Intel ME WMI (`root\Intel_ME`)** | Intel Management Engine and AMT classes (not Samsung, but vendor-exposed). | Out of scope. |
| **Storage / GPU** | Samsung MZVL8512HFLU NVMe (512 GB), Intel Graphics driver 32.0.101.8356. | Standard APIs. |

### Interesting things worth knowing

- The firmware version, BIOS date and board model all match across SMBIOS (assembly),
  WMI (PowerShell) and the registry. That is a good sanity check of the parser.
- SMBIOS also holds a **serial number and UUID**. The example program deliberately never prints them.
- `BiosManager` is how Samsung's own tools can change BIOS options from Windows.
  Treat it like a firmware-write API: it is powerful and unnecessary for learning assembly.
- Features like Quick Share, Multi Control and Samsung Find are cloud and network features
  implemented in apps. They are not hardware APIs you can call from assembly.

## 5. Where to go next

1. Read `cores.asm` and `isalevel.asm` first, since they are short and show real hardware facts.
2. Step through `simd.asm` in GDB and watch the accumulator fill up (`info registers xmm0` shows the
   low 128 bits; this Windows GDB build does not expose the full `ymm` registers).
3. Modify `simd.asm`: change `N` to 8192 (fits in L1) and see how AVX2's speed-up changes.
4. Write a function in assembly, call it from C (they link together), and compare with `gcc -O3`.
5. Learn the stack and calling convention deeper by writing a recursive function (factorial, Fibonacci).
6. Try `RDTSC` timing a single instruction (for example `DIV` vs `SHR`) to feel instruction costs.
