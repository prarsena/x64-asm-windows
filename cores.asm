; =============================================================================
; cores.asm  -  Interrogate every logical processor, one at a time.
;
; Modern Intel CPUs (Alder Lake and later, including this Core Ultra) are
; HYBRID: different cores have different microarchitectures. CPUID answers for
; the core it executes on, so we pin our thread to each core in turn with the
; Windows API SetThreadAffinityMask and ask that core:
;   * which core type it is (CPUID leaf 1Ah: 0x40 = P-core, 0x20 = E-core)
;   * its x2APIC id (CPUID leaf 0Bh)
;   * the size of its L2 cache and whether it can see an L3
;
; Concepts: calling several Windows APIs, loops with state kept on the stack,
;           shifting 1 << n to build an affinity mask, hybrid-CPU detection.
; Build:    .\build.ps1 cores -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

extern GetActiveProcessorCount
extern GetCurrentThread
extern SetThreadAffinityMask
extern GetCurrentProcessorNumber
extern Sleep

ALL_PROCESSOR_GROUPS equ 0xFFFF
CORE_TYPE_ATOM       equ 0x20
CORE_TYPE_CORE       equ 0x40

section .data
s_banner  db "=== cores.asm : per-core hybrid detection ===", 13, 10, 13, 10, 0
s_hybrid  db "CPU reports a hybrid design (CPUID.7:EDX[15]): ", 0
s_count   db "Active logical processors (GetActiveProcessorCount): ", 0
s_head    db 13, 10, "Core-by-core (thread pinned with SetThreadAffinityMask):", 13, 10, 0
s_cpu     db "  CPU ", 0
s_on      db "  ran on ", 0
s_apic    db "  x2APIC ", 0
s_type    db "  ", 0
s_pcore   db "P-core (Intel Core)  ", 0
s_ecore   db "E-core (Intel Atom)  ", 0
s_other   db "unknown type         ", 0
s_l2      db "L2 ", 0
s_kib     db " KiB  L3 visible: ", 0
s_sum     db 13, 10, "Summary:  P-cores = ", 0
s_sume    db "   E-cores = ", 0
s_sumo    db "   other = ", 0

section .text
main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 112
    ; Frame (RBP = RSP + 112):
    ;   [rbp-8] RBX  [rbp-16] cpu index  [rbp-24] cpu count  [rbp-32] core type
    ;   [rbp-40] apic id  [rbp-48] P count  [rbp-56] E count  [rbp-64] other count
    ;   [rbp-72] actual cpu number  [rbp-80] hybrid flag
    mov  [rbp - 8], rbx
    mov  qword [rbp - 48], 0
    mov  qword [rbp - 56], 0
    mov  qword [rbp - 64], 0

    call init_console
    lea  rcx, [s_banner]
    call print_str

    ; Hybrid flag: CPUID leaf 7, sub-leaf 0, EDX bit 15
    mov  eax, 7
    xor  ecx, ecx
    cpuid
    shr  edx, 15
    and  edx, 1
    mov  [rbp - 80], edx                ; keep the flag across the print_str call
    lea  rcx, [s_hybrid]
    call print_str
    mov  ecx, [rbp - 80]
    call print_yesno

    mov  ecx, ALL_PROCESSOR_GROUPS
    call GetActiveProcessorCount
    mov  [rbp - 24], rax
    lea  rcx, [s_count]
    call print_str
    mov  rcx, [rbp - 24]
    call print_dec

    lea  rcx, [s_head]
    call print_str

    mov  qword [rbp - 16], 0
.cpu_loop:
    mov  rax, [rbp - 16]
    cmp  rax, [rbp - 24]
    jae  .summary

    ; ---- Pin this thread to logical processor number [rbp-16] ------------------
    call GetCurrentThread               ; returns a pseudo-handle for this thread
    mov  r8, rax                        ; keep the handle
    mov  rcx, [rbp - 16]
    mov  edx, 1
    shl  rdx, cl                        ; RDX = 1 << index  (affinity bitmask)
    mov  rcx, r8
    call SetThreadAffinityMask
    mov  ecx, 1
    call Sleep                          ; give the scheduler time to move us
    call GetCurrentProcessorNumber
    mov  [rbp - 72], rax

    ; ---- Ask THIS core ----------------------------------------------------------
    mov  eax, 0xB
    xor  ecx, ecx
    cpuid
    mov  [rbp - 40], edx                ; EDX = x2APIC id of the current core

    mov  eax, 0x1A
    xor  ecx, ecx
    cpuid
    shr  eax, 24                        ; EAX[31:24] = core type
    mov  [rbp - 32], rax
    and  qword [rbp - 32], 0xFF

    ; ---- Print one line ----------------------------------------------------------
    lea  rcx, [s_cpu]
    call print_str
    mov  rcx, [rbp - 16]
    call print_udec
    lea  rcx, [s_on]
    call print_str
    mov  rcx, [rbp - 72]
    call print_udec
    lea  rcx, [s_apic]
    call print_str
    mov  ecx, [rbp - 40]
    call print_udec
    lea  rcx, [s_type]
    call print_str

    mov  rax, [rbp - 32]
    cmp  eax, CORE_TYPE_CORE
    je   .is_p
    cmp  eax, CORE_TYPE_ATOM
    je   .is_e
    lea  rcx, [s_other]
    inc  qword [rbp - 64]
    jmp  .type_ready
.is_p:
    lea  rcx, [s_pcore]
    inc  qword [rbp - 48]
    jmp  .type_ready
.is_e:
    lea  rcx, [s_ecore]
    inc  qword [rbp - 56]
.type_ready:
    call print_str

    lea  rcx, [s_l2]
    call print_str
    mov  ecx, 2
    mov  edx, 3
    call cpuid_cache_bytes
    shr  rax, 10
    mov  rcx, rax
    call print_udec
    lea  rcx, [s_kib]
    call print_str
    mov  ecx, 3
    mov  edx, 3
    call cpuid_cache_bytes
    mov  ecx, 0
    test rax, rax
    setnz cl                            ; CL = 1 if an L3 cache was found
    call print_yesno

    inc  qword [rbp - 16]
    jmp  .cpu_loop

.summary:
    lea  rcx, [s_sum]
    call print_str
    mov  rcx, [rbp - 48]
    call print_udec
    lea  rcx, [s_sume]
    call print_str
    mov  rcx, [rbp - 56]
    call print_udec
    lea  rcx, [s_sumo]
    call print_str
    mov  rcx, [rbp - 64]
    call print_dec

    mov  rbx, [rbp - 8]
    xor  ecx, ecx
    call ExitProcess
