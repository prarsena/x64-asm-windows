; =============================================================================
; cpuinfo.asm  -  Report this machine's CPU using the CPUID instruction and
;                 the Windows GetSystemInfo API.  Windows x64, NASM syntax.
;
; Concepts shown:
;   * CPUID instruction (leaves 0, 1, 7, 0x80000002-4)
;   * Bit testing with shift + mask
;   * Calling the Windows API (x64 calling convention, shadow space, alignment)
;   * Writing small reusable functions (print string / decimal / hex)
;   * A NASM macro to avoid repeating code
;
; Build (see README.md):
;   nasm -f win64 cpuinfo.asm -o cpuinfo.obj
;   gcc cpuinfo.obj -o cpuinfo.exe -nostartfiles -Wl,-e,main -lkernel32
; =============================================================================

default rel
bits 64

global main
extern GetStdHandle
extern WriteFile
extern ExitProcess
extern GetSystemInfo

STD_OUTPUT_HANDLE equ -11

; ---------------------------------------------------------------------------
; Macro: SHOW_FLAG local_offset, bit_number, label
;   Takes the 32-bit value saved at [rbp - local_offset], extracts one bit and
;   calls print_flag(name, bit) which prints "  name : yes/no".
; ---------------------------------------------------------------------------
%macro SHOW_FLAG 3
    mov  edx, dword [rbp - %1]  ; load the saved CPUID register
    shr  edx, %2                ; move the wanted bit to position 0
    and  edx, 1                 ; keep only that bit (0 or 1)
    lea  rcx, [%3]              ; RCX = label text
    call print_flag
%endmacro

; Offsets of values saved in main's stack frame (see main for the layout)
L_RBX    equ 8                  ; saved RBX (non-volatile register)
L_LEAF1A equ 16                 ; CPUID.1 EAX  (family/model/stepping)
L_LEAF1C equ 24                 ; CPUID.1 ECX  (feature flags)
L_LEAF1D equ 32                 ; CPUID.1 EDX  (feature flags)
L_LEAF7B equ 40                 ; CPUID.7 EBX  (extended feature flags)
L_MAXLEAF equ 48                ; highest basic CPUID leaf supported

section .data
banner      db "=== cpuinfo.asm : CPUID + GetSystemInfo ===", 13, 10, 13, 10, 0
s_vendor    db "Vendor string        : ", 0
s_brand     db "Brand string         : ", 0
s_maxleaf   db "Max basic CPUID leaf : ", 0
s_family    db "Family               : ", 0
s_model     db "Model                : ", 0
s_stepping  db "Stepping             : ", 0
s_features  db 13, 10, "CPU feature flags (from CPUID):", 13, 10, 0
s_sse2      db "  SSE2     : ", 0
s_sse3      db "  SSE3     : ", 0
s_ssse3     db "  SSSE3    : ", 0
s_sse41     db "  SSE4.1   : ", 0
s_sse42     db "  SSE4.2   : ", 0
s_aes       db "  AES-NI   : ", 0
s_avx       db "  AVX      : ", 0
s_avx2      db "  AVX2     : ", 0
s_avx512    db "  AVX-512F : ", 0
s_sysinfo   db 13, 10, "GetSystemInfo (Windows API):", 13, 10, 0
s_arch      db "  Architecture code  : ", 0
s_page      db "  Page size (bytes)  : ", 0
s_gran      db "  Alloc granularity  : ", 0
s_procs     db "  Logical processors : ", 0
s_minaddr   db "  Min app address    : 0x", 0
s_maxaddr   db "  Max app address    : 0x", 0
s_yes       db "yes", 13, 10, 0
s_no        db "no", 13, 10, 0
crlf        db 13, 10, 0
hexdigits   db "0123456789ABCDEF"

section .bss
hStdout     resq 1              ; console output handle
sysinfo     resb 48             ; SYSTEM_INFO structure is 48 bytes on x64
vendor      resb 13             ; 12 chars + NUL (zero-filled by .bss)
brand       resb 49             ; 48 chars + NUL
numbuf      resb 32             ; scratch buffer for number -> text conversion

section .text

; =============================================================================
; print_str(RCX = pointer to NUL-terminated string)
; Finds the length, then calls WriteFile on the saved stdout handle.
; =============================================================================
print_str:
    push rbp                    ; standard frame: after this RSP is 16-byte aligned
    mov  rbp, rsp
    sub  rsp, 48                ; 32 shadow + 8 (5th arg) + 8 (local 'written')
    mov  rdx, rcx               ; arg2 = buffer
    xor  r8d, r8d               ; r8 = length counter = 0
.len:
    cmp  byte [rdx + r8], 0     ; reached the NUL terminator?
    je   .done
    inc  r8
    jmp  .len
.done:
    mov  rcx, [hStdout]         ; arg1 = handle
    lea  r9, [rbp - 8]          ; arg4 = &bytesWritten (local variable)
    mov  qword [rsp + 32], 0    ; arg5 = lpOverlapped = NULL
    call WriteFile
    leave                       ; mov rsp, rbp / pop rbp
    ret

; =============================================================================
; print_dec(RCX = unsigned 64-bit value)  - prints it in decimal + CRLF
; Repeatedly divides by 10; each remainder is the next digit (right to left).
; =============================================================================
print_dec:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    lea  r10, [numbuf + 31]     ; start at the END of the buffer and write backwards
    mov  byte [r10], 0          ; NUL terminator
    mov  rax, rcx               ; DIV divides RDX:RAX, so the value goes in RAX
    mov  r8d, 10                ; divisor
.loop:
    xor  edx, edx               ; clear the high half (RDX) before DIV
    div  r8                     ; RAX = RAX / 10, RDX = RAX mod 10
    add  dl, '0'                ; digit value -> ASCII character
    dec  r10
    mov  [r10], dl
    test rax, rax               ; any digits left?
    jnz  .loop
    mov  rcx, r10
    call print_str
    lea  rcx, [crlf]
    call print_str
    leave
    ret

; =============================================================================
; print_hex64(RCX = value)  - prints 16 hex digits + CRLF (no 0x prefix)
; Takes the low nibble each time (AND 0xF), looks it up in a table, shifts right 4.
; =============================================================================
print_hex64:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    lea  r10, [numbuf + 16]
    mov  byte [r10], 0
    mov  r8d, 16                ; 16 nibbles in 64 bits
    lea  r9, [hexdigits]
.loop:
    mov  rax, rcx
    and  eax, 0xF               ; low nibble (also zero-extends into RAX)
    mov  al, [r9 + rax]         ; table lookup -> ASCII
    dec  r10
    mov  [r10], al
    shr  rcx, 4                 ; next nibble
    dec  r8d
    jnz  .loop
    mov  rcx, r10
    call print_str
    lea  rcx, [crlf]
    call print_str
    leave
    ret

; =============================================================================
; print_flag(RCX = label string, RDX = 0 or 1)  - prints label then yes/no
; =============================================================================
print_flag:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    mov  [rbp - 8], rdx         ; RDX is volatile: save it across the call
    call print_str              ; prints the label already in RCX
    mov  rdx, [rbp - 8]
    lea  rcx, [s_no]
    test rdx, rdx
    jz   .print
    lea  rcx, [s_yes]
.print:
    call print_str
    leave
    ret

; =============================================================================
; main - program entry point
; Frame layout (RBP = RSP + 80):
;   [rbp-8]  saved RBX   [rbp-16] leaf1 EAX   [rbp-24] leaf1 ECX
;   [rbp-32] leaf1 EDX   [rbp-40] leaf7 EBX   [rbp-48] max leaf
; =============================================================================
main:
    push rbp                    ; entry RSP is 8 mod 16; push makes it 16-aligned
    mov  rbp, rsp
    sub  rsp, 80                ; locals + 32 bytes shadow space (multiple of 16)

    ; CPUID overwrites RBX, which Windows requires us to preserve -> save it.
    mov  [rbp - L_RBX], rbx

    ; Get the console handle once and keep it in a global.
    mov  ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov  [hStdout], rax

    lea  rcx, [banner]
    call print_str

    ; ---- CPUID leaf 0: highest leaf + 12-char vendor string ----------------
    ; Input EAX=0.  Output: EAX = max leaf, vendor in EBX:EDX:ECX (in that order!).
    xor  eax, eax
    cpuid
    mov  [rbp - L_MAXLEAF], eax
    mov  [vendor], ebx          ; "Genu"
    mov  [vendor + 4], edx      ; "ineI"
    mov  [vendor + 8], ecx      ; "ntel"

    lea  rcx, [s_vendor]
    call print_str
    lea  rcx, [vendor]
    call print_str
    lea  rcx, [crlf]
    call print_str

    ; ---- CPUID leaves 0x80000002..0x80000004: 48-char brand string ----------
    ; Each leaf returns 16 characters in EAX, EBX, ECX, EDX.
    mov  r8d, 0x80000002        ; current leaf (R8 survives CPUID)
    lea  r9, [brand]            ; write pointer
.brand_loop:
    mov  eax, r8d
    cpuid
    mov  [r9], eax
    mov  [r9 + 4], ebx
    mov  [r9 + 8], ecx
    mov  [r9 + 12], edx
    add  r9, 16
    inc  r8d
    cmp  r8d, 0x80000004
    jbe  .brand_loop            ; unsigned compare: loop while leaf <= 0x80000004

    lea  rcx, [s_brand]
    call print_str
    lea  rcx, [brand]
    call print_str
    lea  rcx, [crlf]
    call print_str

    lea  rcx, [s_maxleaf]
    call print_str
    mov  ecx, [rbp - L_MAXLEAF]
    call print_dec

    ; ---- CPUID leaf 1: family / model / stepping and feature flags ----------
    mov  eax, 1
    cpuid
    mov  [rbp - L_LEAF1A], eax
    mov  [rbp - L_LEAF1C], ecx
    mov  [rbp - L_LEAF1D], edx

    ; Family = base family (bits 11:8), plus extended family (27:20) when base == 0xF
    lea  rcx, [s_family]
    call print_str
    mov  eax, [rbp - L_LEAF1A]
    mov  ecx, eax
    shr  ecx, 8
    and  ecx, 0xF               ; ECX = base family
    cmp  ecx, 0xF
    jne  .family_ready
    mov  edx, eax
    shr  edx, 20
    and  edx, 0xFF              ; extended family
    add  ecx, edx
.family_ready:
    call print_dec

    ; Model = base model (7:4), plus extended model (19:16) << 4 when family is 6 or 15
    lea  rcx, [s_model]
    call print_str
    mov  eax, [rbp - L_LEAF1A]
    mov  ecx, eax
    shr  ecx, 4
    and  ecx, 0xF               ; ECX = base model
    mov  edx, eax
    shr  edx, 8
    and  edx, 0xF               ; EDX = base family
    cmp  edx, 6
    je   .use_ext_model
    cmp  edx, 0xF
    jne  .model_ready
.use_ext_model:
    mov  edx, eax
    shr  edx, 16
    and  edx, 0xF               ; extended model
    shl  edx, 4
    or   ecx, edx
.model_ready:
    call print_dec

    ; Stepping = bits 3:0
    lea  rcx, [s_stepping]
    call print_str
    mov  ecx, [rbp - L_LEAF1A]
    and  ecx, 0xF
    call print_dec

    ; ---- CPUID leaf 7 (sub-leaf 0): AVX2 / AVX-512 flags ---------------------
    mov  dword [rbp - L_LEAF7B], 0      ; default: all clear if leaf 7 is unsupported
    cmp  dword [rbp - L_MAXLEAF], 7
    jb   .no_leaf7
    mov  eax, 7
    xor  ecx, ecx               ; sub-leaf 0 (leaf 7 takes ECX as input too)
    cpuid
    mov  [rbp - L_LEAF7B], ebx
.no_leaf7:

    lea  rcx, [s_features]
    call print_str

    ; Feature bits: CPUID.1:EDX[26]=SSE2, CPUID.1:ECX[0]=SSE3, [9]=SSSE3,
    ; [19]=SSE4.1, [20]=SSE4.2, [25]=AES, [28]=AVX; CPUID.7:EBX[5]=AVX2, [16]=AVX512F
    SHOW_FLAG L_LEAF1D, 26, s_sse2
    SHOW_FLAG L_LEAF1C, 0,  s_sse3
    SHOW_FLAG L_LEAF1C, 9,  s_ssse3
    SHOW_FLAG L_LEAF1C, 19, s_sse41
    SHOW_FLAG L_LEAF1C, 20, s_sse42
    SHOW_FLAG L_LEAF1C, 25, s_aes
    SHOW_FLAG L_LEAF1C, 28, s_avx
    SHOW_FLAG L_LEAF7B, 5,  s_avx2
    SHOW_FLAG L_LEAF7B, 16, s_avx512

    ; ---- Windows API: GetSystemInfo(&sysinfo) --------------------------------
    ; SYSTEM_INFO offsets (x64): 0 arch(WORD) 4 pageSize 8 minAddr 16 maxAddr
    ;                            32 numProcessors 40 allocGranularity
    lea  rcx, [s_sysinfo]
    call print_str
    lea  rcx, [sysinfo]
    call GetSystemInfo

    lea  rcx, [s_arch]
    call print_str
    movzx ecx, word [sysinfo]   ; 16-bit field, zero-extended
    call print_dec

    lea  rcx, [s_page]
    call print_str
    mov  ecx, [sysinfo + 4]
    call print_dec

    lea  rcx, [s_gran]
    call print_str
    mov  ecx, [sysinfo + 40]
    call print_dec

    lea  rcx, [s_procs]
    call print_str
    mov  ecx, [sysinfo + 32]
    call print_dec

    lea  rcx, [s_minaddr]
    call print_str
    mov  rcx, [sysinfo + 8]
    call print_hex64

    lea  rcx, [s_maxaddr]
    call print_str
    mov  rcx, [sysinfo + 16]
    call print_hex64

    ; ---- Clean exit -----------------------------------------------------------
    mov  rbx, [rbp - L_RBX]     ; restore RBX (good habit even though we exit)
    xor  ecx, ecx
    call ExitProcess
