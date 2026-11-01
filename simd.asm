; =============================================================================
; simd.asm  -  The raw power of assembly: SIMD (Single Instruction, Multiple Data)
;
; Task: add up 32,768 32-bit integers (128 KiB), repeated 20,000 times.
;   1. scalar : one integer per instruction                (1 x 32-bit)
;   2. SSE2   : 4 integers per instruction, 2 accumulators (8 per loop pass)
;   3. AVX2   : 8 integers per instruction, 4 accumulators (32 per loop pass)
; The program checks every answer and prints time and speed-up.
;
; Why several accumulators? One chain of dependent adds can only run as fast as
; the add's latency. Independent chains let the CPU overlap them.
;
; Concepts: XMM/YMM registers, PADDD/VPADDD, horizontal sums, XGETBV check for
;           OS support, QueryPerformanceCounter timing, function pointers.
; Build:    .\build.ps1 simd -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

extern QueryPerformanceFrequency
extern QueryPerformanceCounter

N        equ 32768                      ; number of int32 elements (multiple of 32)
REPS     equ 20000
EXPECTED equ N * (N + 1) / 2            ; data holds 1..N, so the sum is known

section .data
s_banner  db "=== simd.asm : scalar vs SSE2 vs AVX2 ===", 13, 10
          db "Summing 32768 ints (128 KiB) x 20000 repetitions", 13, 10, 13, 10, 0
s_scalar  db "  scalar (1 int / add)  : ", 0
s_sse2    db "  SSE2   (4 ints / add) : ", 0
s_avx2    db "  AVX2   (8 ints / add) : ", 0
s_us      db " us  ", 0
s_ok      db "[correct]", 13, 10, 0
s_bad     db "[WRONG RESULT]", 13, 10, 0
s_noavx   db "  AVX2 not usable here (CPU or OS lacks support) - skipped", 13, 10, 0
s_speed   db 13, 10, "Speed-up over scalar:", 13, 10, 0
s_sse2x   db "  SSE2 : ", 0
s_avx2x   db "  AVX2 : ", 0
s_x       db "x", 13, 10, 0
s_dot     db ".", 0

section .bss
data        resd N                      ; the array (int32)
qpc_freq    resq 1
last_result resd 1
t_scalar    resq 1                      ; elapsed microseconds per method
t_sse2      resq 1
t_avx2      resq 1

section .text

; -----------------------------------------------------------------------------
; Each summing function:  RCX = pointer to int32 array,  EDX = element count
;                         returns the 32-bit sum in EAX
; They are leaf functions (no calls), so no stack frame is needed.
; -----------------------------------------------------------------------------
sum_scalar:
    xor  eax, eax
.loop:
    add  eax, [rcx]                     ; accumulate one element
    add  rcx, 4
    dec  edx
    jnz  .loop
    ret

sum_sse2:
    pxor xmm0, xmm0                     ; accumulator A (4 lanes of 32 bits)
    pxor xmm1, xmm1                     ; accumulator B
    shr  edx, 3                         ; 8 elements per pass
.loop:
    movdqu xmm2, [rcx]                  ; load 4 ints (unaligned load)
    movdqu xmm3, [rcx + 16]
    paddd  xmm0, xmm2                   ; 4 additions at once
    paddd  xmm1, xmm3
    add  rcx, 32
    dec  edx
    jnz  .loop
    paddd xmm0, xmm1                    ; combine accumulators
    pshufd xmm1, xmm0, 0x4E             ; swap the two 64-bit halves
    paddd xmm0, xmm1
    pshufd xmm1, xmm0, 0xB1             ; swap adjacent 32-bit lanes
    paddd xmm0, xmm1                    ; every lane now holds the total
    movd eax, xmm0
    ret

sum_avx2:
    vpxor ymm0, ymm0, ymm0              ; four 256-bit accumulators (8 lanes each)
    vpxor ymm1, ymm1, ymm1
    vpxor ymm2, ymm2, ymm2
    vpxor ymm3, ymm3, ymm3
    shr  edx, 5                         ; 32 elements per pass
.loop:
    vpaddd ymm0, ymm0, [rcx]            ; VEX encoding: memory operand may be unaligned
    vpaddd ymm1, ymm1, [rcx + 32]
    vpaddd ymm2, ymm2, [rcx + 64]
    vpaddd ymm3, ymm3, [rcx + 96]
    sub  rcx, -128                      ; same as add rcx,128 with a shorter encoding
    dec  edx
    jnz  .loop
    vpaddd ymm0, ymm0, ymm1
    vpaddd ymm2, ymm2, ymm3
    vpaddd ymm0, ymm0, ymm2
    vextracti128 xmm1, ymm0, 1          ; upper 128 bits -> xmm1
    vpaddd xmm0, xmm0, xmm1
    vpshufd xmm1, xmm0, 0x4E
    vpaddd xmm0, xmm0, xmm1
    vpshufd xmm1, xmm0, 0xB1
    vpaddd xmm0, xmm0, xmm1
    vmovd eax, xmm0
    vzeroupper                          ; avoid slow AVX<->SSE transitions afterwards
    ret

; -----------------------------------------------------------------------------
; has_avx2() -> EAX = 1 if the CPU supports AVX2 AND the OS saves YMM registers
; -----------------------------------------------------------------------------
has_avx2:
    push rbx
    mov  eax, 1
    cpuid
    mov  r8d, ecx
    and  r8d, (1 << 27) | (1 << 28)     ; OSXSAVE and AVX
    cmp  r8d, (1 << 27) | (1 << 28)
    jne  .no
    xor  ecx, ecx
    xgetbv                              ; XCR0: did the OS enable XMM+YMM state?
    and  eax, 6
    cmp  eax, 6
    jne  .no
    mov  eax, 7
    xor  ecx, ecx
    cpuid
    bt   ebx, 5                         ; CPUID.7:EBX[5] = AVX2
    jnc  .no
    mov  eax, 1
    pop  rbx
    ret
.no:
    xor  eax, eax
    pop  rbx
    ret

; -----------------------------------------------------------------------------
; bench(RCX = function) -> RAX = elapsed QueryPerformanceCounter ticks
; Calls the function REPS times and stores the last result in last_result.
; -----------------------------------------------------------------------------
bench:
    push rbp
    mov  rbp, rsp
    sub  rsp, 64
    mov  [rbp - 8], rcx                 ; function pointer
    lea  rcx, [rbp - 16]
    call QueryPerformanceCounter        ; start time
    mov  dword [rbp - 24], REPS
.rep:
    lea  rcx, [data]
    mov  edx, N
    call [rbp - 8]                      ; indirect call through the pointer
    mov  [last_result], eax
    dec  dword [rbp - 24]
    jnz  .rep
    lea  rcx, [rbp - 32]
    call QueryPerformanceCounter        ; end time
    mov  rax, [rbp - 32]
    sub  rax, [rbp - 16]
    leave
    ret

; -----------------------------------------------------------------------------
; run_one(RCX = label, RDX = function, R8 = where to store microseconds)
; -----------------------------------------------------------------------------
run_one:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    mov  [rbp - 8], rdx
    mov  [rbp - 16], r8
    call print_str                      ; label is already in RCX
    mov  rcx, [rbp - 8]
    call bench
    mov  ecx, 1000000
    mul  rcx                            ; RDX:RAX = ticks * 1,000,000
    div  qword [qpc_freq]               ; RAX = microseconds
    mov  rcx, [rbp - 16]
    mov  [rcx], rax
    mov  rcx, rax
    call print_udec
    lea  rcx, [s_us]
    call print_str
    lea  rcx, [s_ok]
    cmp  dword [last_result], EXPECTED
    je   .print
    lea  rcx, [s_bad]
.print:
    call print_str
    leave
    ret

; print_ratio(RCX = numerator, RDX = denominator): prints num/den with 1 decimal + "x"
print_ratio:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    mov  r9, rdx
    imul rax, rcx, 10                   ; scale by 10 to keep one decimal digit
    xor  edx, edx
    div  r9                             ; RAX = ratio * 10
    mov  [rbp - 8], rax
    xor  edx, edx
    mov  ecx, 10
    div  rcx                            ; RAX = whole part, RDX = tenths
    mov  [rbp - 16], rdx
    mov  rcx, rax
    call print_udec
    lea  rcx, [s_dot]
    call print_str
    mov  rcx, [rbp - 16]
    call print_udec
    lea  rcx, [s_x]
    call print_str
    leave
    ret

main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    call init_console
    lea  rcx, [qpc_freq]
    call QueryPerformanceFrequency

    ; Fill data[i] = i + 1
    lea  rdx, [data]
    mov  ecx, 1
    mov  r8d, N
.fill:
    mov  [rdx], ecx
    add  rdx, 4
    inc  ecx
    dec  r8d
    jnz  .fill

    lea  rcx, [s_banner]
    call print_str

    lea  rcx, [s_scalar]
    lea  rdx, [sum_scalar]
    lea  r8, [t_scalar]
    call run_one

    lea  rcx, [s_sse2]
    lea  rdx, [sum_sse2]
    lea  r8, [t_sse2]
    call run_one

    call has_avx2
    test eax, eax
    jz   .no_avx2
    lea  rcx, [s_avx2]
    lea  rdx, [sum_avx2]
    lea  r8, [t_avx2]
    call run_one

    lea  rcx, [s_speed]
    call print_str
    lea  rcx, [s_sse2x]
    call print_str
    mov  rcx, [t_scalar]
    mov  rdx, [t_sse2]
    call print_ratio
    lea  rcx, [s_avx2x]
    call print_str
    mov  rcx, [t_scalar]
    mov  rdx, [t_avx2]
    call print_ratio
    jmp  .exit

.no_avx2:
    lea  rcx, [s_noavx]
    call print_str
.exit:
    xor  ecx, ecx
    call ExitProcess
