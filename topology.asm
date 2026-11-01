; =============================================================================
; topology.asm  -  Cache sizes, clock rates and address widths of THIS machine,
;                  read straight from the CPU with CPUID and RDTSC.
;
; Cross-check with what Windows told us: L2 = 16384 KB, L3 = 12288 KB (WMI).
;
; Concepts: CPUID leaves 4, 0xB, 0x15, 0x16, 0x80000008; RDTSC (cycle counter);
;           QueryPerformanceCounter; 128-bit multiply/divide (MUL / DIV).
; Build:    .\build.ps1 topology -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

extern QueryPerformanceFrequency
extern QueryPerformanceCounter
extern Sleep

; CACHE label, level, type : prints "<label><size in KiB> KiB"
%macro CACHE 3
    lea  rcx, [%1]
    call print_str
    mov  ecx, %2
    mov  edx, %3
    call cpuid_cache_bytes      ; RAX = bytes (0 if this cache does not exist)
    shr  rax, 10                ; bytes -> KiB
    mov  rcx, rax
    call print_udec
    lea  rcx, [s_kib]
    call print_str
%endmacro

section .data
s_banner  db "=== topology.asm : caches, clocks, address widths ===", 13, 10, 13, 10, 0
s_caches  db "Caches seen by the core running this program (CPUID leaf 4):", 13, 10, 0
s_l1d     db "  L1 data        : ", 0
s_l1i     db "  L1 instruction : ", 0
s_l2      db "  L2 unified     : ", 0
s_l3      db "  L3 unified     : ", 0
s_kib     db " KiB", 13, 10, 0
s_smt     db 13, 10, "Logical processors per core (leaf 0Bh)  : ", 0
s_pkg     db "Logical processors in the package       : ", 0
s_addr    db 13, 10, "Address widths (leaf 80000008h):", 13, 10, 0
s_phys    db "  Physical address bits : ", 0
s_virt    db "  Virtual address bits  : ", 0
s_freq    db 13, 10, "Frequencies reported by CPUID leaf 16h (MHz):", 13, 10, 0
s_base    db "  Base : ", 0
s_max     db "  Max  : ", 0
s_bus     db "  Bus  : ", 0
s_nofreq  db "  (leaf 16h not supported)", 13, 10, 0
s_tsc15   db 13, 10, "TSC / crystal information (CPUID leaf 15h):", 13, 10, 0
s_ratio   db "  TSC = crystal * ", 0
s_slash   db " / ", 0
s_xtal    db "  Crystal clock (Hz)   : ", 0
s_tsccalc db "  Computed TSC (MHz)   : ", 0
s_noxtal  db "  (crystal frequency not enumerated by this CPU)", 13, 10, 0
s_meas    db 13, 10, "Measured TSC rate over 200 ms using QueryPerformanceCounter (MHz): ", 0
s_note    db 13, 10, "Note: the TSC ticks at a constant rate; it is NOT the current core clock.", 13, 10, 0

section .text
main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 112
    ; Frame (RBP = RSP + 112):
    ;   [rbp-8] saved RBX  [rbp-16] max CPUID leaf  [rbp-24]/[rbp-32]/[rbp-40] saved regs
    ;   [rbp-48] QPC start [rbp-56] TSC start       [rbp-64] QPC frequency  [rbp-72] QPC end
    mov  [rbp - 8], rbx

    call init_console
    lea  rcx, [s_banner]
    call print_str

    xor  eax, eax
    cpuid
    mov  [rbp - 16], eax                ; highest basic leaf

    ; ---- Caches ----------------------------------------------------------------
    lea  rcx, [s_caches]
    call print_str
    CACHE s_l1d, 1, 1
    CACHE s_l1i, 1, 2
    CACHE s_l2,  2, 3
    CACHE s_l3,  3, 3

    ; ---- Leaf 0Bh: topology (sub-leaf 0 = SMT level, sub-leaf 1 = core level) ---
    mov  eax, 0xB
    xor  ecx, ecx
    cpuid
    movzx eax, bx                       ; EBX[15:0] = logical processors at this level
    mov  [rbp - 24], eax
    mov  eax, 0xB
    mov  ecx, 1
    cpuid
    movzx eax, bx
    mov  [rbp - 32], eax

    lea  rcx, [s_smt]
    call print_str
    mov  ecx, [rbp - 24]
    call print_dec
    lea  rcx, [s_pkg]
    call print_str
    mov  ecx, [rbp - 32]
    call print_dec

    ; ---- Leaf 80000008h: address sizes -------------------------------------------
    mov  eax, 0x80000008
    cpuid
    mov  [rbp - 24], eax
    lea  rcx, [s_addr]
    call print_str
    lea  rcx, [s_phys]
    call print_str
    movzx ecx, byte [rbp - 24]          ; EAX[7:0]
    call print_dec
    lea  rcx, [s_virt]
    call print_str
    movzx ecx, byte [rbp - 23]          ; EAX[15:8] = the next byte up
    call print_dec

    ; ---- Leaf 16h: base / max / bus frequency ------------------------------------
    lea  rcx, [s_freq]
    call print_str
    cmp  dword [rbp - 16], 0x16
    jb   .no16
    mov  eax, 0x16
    cpuid
    mov  [rbp - 24], eax
    mov  [rbp - 32], ebx
    mov  [rbp - 40], ecx
    lea  rcx, [s_base]
    call print_str
    movzx ecx, word [rbp - 24]
    call print_dec
    lea  rcx, [s_max]
    call print_str
    movzx ecx, word [rbp - 32]
    call print_dec
    lea  rcx, [s_bus]
    call print_str
    movzx ecx, word [rbp - 40]
    call print_dec
    jmp  .leaf15
.no16:
    lea  rcx, [s_nofreq]
    call print_str

    ; ---- Leaf 15h: TSC-to-crystal ratio ----------------------------------------
.leaf15:
    lea  rcx, [s_tsc15]
    call print_str
    cmp  dword [rbp - 16], 0x15
    jb   .noxtal
    mov  eax, 0x15
    cpuid
    mov  [rbp - 24], eax                ; denominator
    mov  [rbp - 32], ebx                ; numerator
    mov  [rbp - 40], ecx                ; crystal Hz
    test eax, eax
    jz   .noxtal
    test ecx, ecx
    jz   .noxtal
    lea  rcx, [s_ratio]
    call print_str
    mov  ecx, [rbp - 32]
    call print_udec
    lea  rcx, [s_slash]
    call print_str
    mov  ecx, [rbp - 24]
    call print_dec
    lea  rcx, [s_xtal]
    call print_str
    mov  ecx, [rbp - 40]
    call print_dec
    ; TSC Hz = crystal * numerator / denominator
    mov  eax, [rbp - 40]
    mov  ecx, [rbp - 32]
    imul rax, rcx
    xor  edx, edx
    mov  ecx, [rbp - 24]
    div  rcx
    xor  edx, edx
    mov  ecx, 1000000
    div  rcx                            ; Hz -> MHz
    mov  [rbp - 40], rax
    lea  rcx, [s_tsccalc]
    call print_str
    mov  rcx, [rbp - 40]
    call print_dec
    jmp  .measure
.noxtal:
    lea  rcx, [s_noxtal]
    call print_str

    ; ---- Measure the TSC against the Windows performance counter -----------------
.measure:
    lea  rcx, [rbp - 64]
    call QueryPerformanceFrequency      ; ticks per second
    lea  rcx, [rbp - 48]
    call QueryPerformanceCounter
    lfence                              ; keep RDTSC from executing too early
    rdtsc                               ; EDX:EAX = cycle counter
    shl  rdx, 32
    or   rax, rdx
    mov  [rbp - 56], rax

    mov  ecx, 200
    call Sleep                          ; wait 200 ms

    lea  rcx, [rbp - 72]
    call QueryPerformanceCounter
    lfence
    rdtsc
    shl  rdx, 32
    or   rax, rdx
    sub  rax, [rbp - 56]                ; RAX = TSC ticks elapsed
    mov  r8, [rbp - 72]
    sub  r8, [rbp - 48]                 ; R8  = QPC ticks elapsed
    mul  qword [rbp - 64]               ; RDX:RAX = tscTicks * qpcFrequency (128-bit)
    div  r8                             ; RAX = TSC Hz
    xor  edx, edx
    mov  ecx, 1000000
    div  rcx                            ; Hz -> MHz
    mov  [rbp - 40], rax

    lea  rcx, [s_meas]
    call print_str
    mov  rcx, [rbp - 40]
    call print_dec
    lea  rcx, [s_note]
    call print_str

    mov  rbx, [rbp - 8]
    xor  ecx, ecx
    call ExitProcess
