; =============================================================================
; isalevel.asm  -  Which "version" of x86-64 assembly does this CPU speak?
;
; x86-64 has no single version number. Instead, compilers and OS vendors group
; instruction-set extensions into four standard LEVELS (the x86-64 psABI):
;   v1  baseline x86-64 (SSE2)            v3  + AVX, AVX2, BMI1/2, FMA, ...
;   v2  + SSE3/4.2, POPCNT, CMPXCHG16B    v4  + AVX-512 (F, BW, CD, DQ, VL)
; This program tests every feature with CPUID and reports the highest level.
;
; Concepts: table-driven code, CPUID sub-leaves, XGETBV (OS support), BT/shifts.
; Build:    .\build.ps1 isalevel -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

; ---- Feature table ----------------------------------------------------------
; Each record is 28 bytes:  name[16] | leaf (dd) | sub-leaf (dd) | reg | bit | level | pad
; reg selects the CPUID output register: 0=EAX 1=EBX 2=ECX 3=EDX
REC_SIZE equ 28

%macro FEAT 6                   ; name, level, leaf, subleaf, reg, bit
%%start:
    db   %1
    times 15 - ($ - %%start) db ' '     ; pad the name to 15 chars so columns line up
    db   0                              ; NUL terminator -> record name is 16 bytes
    dd   %3, %4
    db   %5, %6, %2, 0
%endmacro

section .data
feature_table:
    FEAT "CMOV",       1, 1, 0, 3, 15
    FEAT "FXSR",       1, 1, 0, 3, 24
    FEAT "SSE2",       1, 1, 0, 3, 26
    FEAT "CMPXCHG16B", 2, 1, 0, 2, 13
    FEAT "LAHF/SAHF",  2, 0x80000001, 0, 2, 0
    FEAT "POPCNT",     2, 1, 0, 2, 23
    FEAT "SSE3",       2, 1, 0, 2, 0
    FEAT "SSSE3",      2, 1, 0, 2, 9
    FEAT "SSE4.1",     2, 1, 0, 2, 19
    FEAT "SSE4.2",     2, 1, 0, 2, 20
    FEAT "AVX",        3, 1, 0, 2, 28
    FEAT "AVX2",       3, 7, 0, 1, 5
    FEAT "BMI1",       3, 7, 0, 1, 3
    FEAT "BMI2",       3, 7, 0, 1, 8
    FEAT "F16C",       3, 1, 0, 2, 29
    FEAT "FMA",        3, 1, 0, 2, 12
    FEAT "LZCNT",      3, 0x80000001, 0, 2, 5
    FEAT "MOVBE",      3, 1, 0, 2, 22
    FEAT "OSXSAVE",    3, 1, 0, 2, 27
    FEAT "AVX512F",    4, 7, 0, 1, 16
    FEAT "AVX512BW",   4, 7, 0, 1, 30
    FEAT "AVX512CD",   4, 7, 0, 1, 28
    FEAT "AVX512DQ",   4, 7, 0, 1, 17
    FEAT "AVX512VL",   4, 7, 0, 1, 31
    ; Level 0 = not part of any level, just interesting extras
    FEAT "AES-NI",     0, 1, 0, 2, 25
    FEAT "PCLMULQDQ",  0, 1, 0, 2, 1
    FEAT "RDRAND",     0, 1, 0, 2, 30
    FEAT "RDSEED",     0, 7, 0, 1, 18
    FEAT "SHA",        0, 7, 0, 1, 29
    FEAT "ADX",        0, 7, 0, 1, 19
    FEAT "VAES",       0, 7, 0, 2, 9
    FEAT "AVX-VNNI",   0, 7, 1, 0, 4
feature_table_end:
FEAT_COUNT equ (feature_table_end - feature_table) / REC_SIZE

s_banner  db "=== isalevel.asm : x86-64 instruction-set level ===", 13, 10
          db "  vN = required by x86-64-vN,  + = extra feature", 13, 10, 13, 10, 0
s_v       db "  v", 0
s_sp      db " ", 0
s_extra   db "  +  ", 0
s_os_ymm  db 13, 10, "OS saves AVX (YMM) state   : ", 0
s_os_zmm  db "OS saves AVX-512 (ZMM) state: ", 0
s_level   db 13, 10, "Highest level supported: x86-64-v", 0
s_hint    db "Compile C for it with:  gcc -march=x86-64-v", 0

section .text
main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96
    ; Frame (RBP = RSP + 96):
    ;   [rbp-8] saved RBX   [rbp-16] level mask   [rbp-24] record pointer
    ;   [rbp-32] records left   [rbp-48..-33] CPUID output   [rbp-52] "present" flag
    ;   [rbp-56] OS YMM ok   [rbp-60] OS ZMM ok
    mov  [rbp - 8], rbx

    call init_console
    lea  rcx, [s_banner]
    call print_str

    mov  dword [rbp - 16], 0x1E         ; bits 1..4 set = "levels 1-4 still possible"
    lea  rax, [feature_table]
    mov  [rbp - 24], rax
    mov  dword [rbp - 32], FEAT_COUNT

.loop:
    mov  r8, [rbp - 24]
    mov  eax, [r8 + 16]                 ; leaf
    mov  ecx, [r8 + 20]                 ; sub-leaf
    cpuid
    mov  [rbp - 48], eax                ; store the four outputs in memory order
    mov  [rbp - 44], ebx
    mov  [rbp - 40], ecx
    mov  [rbp - 36], edx

    mov  r8, [rbp - 24]
    movzx ecx, byte [r8 + 24]           ; which register?
    mov  eax, [rbp - 48 + rcx * 4]      ; index into the saved array
    movzx ecx, byte [r8 + 25]           ; which bit?
    shr  eax, cl
    and  eax, 1
    mov  [rbp - 52], eax

    movzx ecx, byte [r8 + 26]           ; level (0 = extra)
    test ecx, ecx
    jz   .extra
    lea  rcx, [s_v]
    call print_str
    mov  r8, [rbp - 24]
    movzx ecx, byte [r8 + 26]
    call print_udec
    lea  rcx, [s_sp]
    call print_str
    jmp  .name
.extra:
    lea  rcx, [s_extra]
    call print_str
.name:
    mov  rcx, [rbp - 24]                ; the name is the first field of the record
    call print_str
    mov  ecx, [rbp - 52]
    call print_yesno

    ; A missing feature disqualifies its level (and therefore all higher levels).
    cmp  dword [rbp - 52], 0
    jne  .next
    mov  r8, [rbp - 24]
    movzx ecx, byte [r8 + 26]
    test ecx, ecx
    jz   .next
    mov  eax, 1
    shl  eax, cl
    not  eax
    and  [rbp - 16], eax
.next:
    add  qword [rbp - 24], REC_SIZE
    dec  dword [rbp - 32]
    jnz  .loop

    ; ---- Does the OS actually save the wide registers? ------------------------
    ; The CPU may have AVX, but the OS must enable it via XCR0, read with XGETBV.
    ; XCR0 bit 1 = SSE state, bit 2 = YMM state, bits 5-7 = ZMM / opmask state.
    mov  dword [rbp - 56], 0
    mov  dword [rbp - 60], 0
    mov  eax, 1
    cpuid
    test ecx, 1 << 27                   ; OSXSAVE: XGETBV is allowed
    jz   .osdone
    xor  ecx, ecx                       ; XCR0
    xgetbv                              ; EDX:EAX = XCR0
    mov  edx, eax
    and  edx, 0x6
    cmp  edx, 0x6
    jne  .osdone
    mov  dword [rbp - 56], 1
    and  eax, 0xE0
    cmp  eax, 0xE0
    jne  .osdone
    mov  dword [rbp - 60], 1
.osdone:
    lea  rcx, [s_os_ymm]
    call print_str
    mov  ecx, [rbp - 56]
    call print_yesno
    lea  rcx, [s_os_zmm]
    call print_str
    mov  ecx, [rbp - 60]
    call print_yesno

    cmp  dword [rbp - 56], 0
    jne  .ymm_ok
    and  dword [rbp - 16], ~(1 << 3) & 0xFF     ; no OS support -> not v3
.ymm_ok:
    cmp  dword [rbp - 60], 0
    jne  .zmm_ok
    and  dword [rbp - 16], ~(1 << 4) & 0xFF     ; no OS support -> not v4
.zmm_ok:

    ; ---- Highest level = number of consecutive set bits starting at bit 1 ------
    mov  eax, [rbp - 16]
    xor  ecx, ecx
.level:
    inc  ecx
    bt   eax, ecx                       ; copy bit ECX of EAX into the carry flag
    jc   .level
    dec  ecx                            ; ECX = highest level
    mov  [rbp - 52], ecx

    lea  rcx, [s_level]
    call print_str
    mov  ecx, [rbp - 52]
    call print_dec
    lea  rcx, [s_hint]
    call print_str
    mov  ecx, [rbp - 52]
    call print_dec

    mov  rbx, [rbp - 8]
    xor  ecx, ecx
    call ExitProcess
