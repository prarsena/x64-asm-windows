; =============================================================================
; common.inc  -  Shared helpers for the example programs (NASM, Windows x64)
;
; Usage:   %include "common.inc"      (near the top, after 'default rel' / 'bits 64')
;          call init_console          (once, at the start of main)
;
; Provided routines (all follow the Windows x64 calling convention):
;   init_console                       open stdout
;   print_str(rcx=ptr)                 print NUL-terminated string
;   print_crlf()                       print a newline
;   print_udec(rcx=value)              print unsigned decimal, no newline
;   print_dec(rcx=value)               print unsigned decimal + newline
;   print_hex64(rcx=value)             print 16 hex digits, no newline
;   print_hex_bytes(rcx=ptr, rdx=n)    print n bytes as hex pairs, no newline
;   print_yesno(ecx=0/1)               print "yes"/"no" + newline
;   cpuid_cache_bytes(ecx=level, edx=type)  -> rax = size in bytes (0 if absent)
;                                      type: 1=data, 2=instruction, 3=unified
; =============================================================================

extern GetStdHandle
extern WriteFile
extern ExitProcess

STD_OUTPUT_HANDLE equ -11

section .data
crlf_str    db 13, 10, 0
hexdigits   db "0123456789ABCDEF"
yes_str     db "yes", 13, 10, 0
no_str      db "no", 13, 10, 0

section .bss
hStdout     resq 1              ; console handle, set by init_console
numbuf      resb 80             ; scratch buffer for number -> text

section .text

init_console:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                ; shadow space only (GetStdHandle has 1 argument)
    mov  ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov  [hStdout], rax
    leave
    ret

; print_str(RCX = pointer to NUL-terminated string)
print_str:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48                ; 32 shadow + 8 (5th arg) + 8 (local 'written')
    mov  rdx, rcx               ; arg2 = buffer
    xor  r8d, r8d               ; r8 = length
.len:
    cmp  byte [rdx + r8], 0
    je   .done
    inc  r8
    jmp  .len
.done:
    mov  rcx, [hStdout]
    lea  r9, [rbp - 8]          ; &bytesWritten
    mov  qword [rsp + 32], 0    ; lpOverlapped = NULL
    call WriteFile
    leave
    ret

print_crlf:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    lea  rcx, [crlf_str]
    call print_str
    leave
    ret

; print_udec(RCX = value): repeated division by 10, digits produced right-to-left
print_udec:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    lea  r10, [numbuf + 79]
    mov  byte [r10], 0
    mov  rax, rcx
    mov  r8d, 10
.loop:
    xor  edx, edx               ; DIV uses RDX:RAX as the dividend
    div  r8
    add  dl, '0'
    dec  r10
    mov  [r10], dl
    test rax, rax
    jnz  .loop
    mov  rcx, r10
    call print_str
    leave
    ret

print_dec:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    call print_udec
    call print_crlf
    leave
    ret

; print_hex64(RCX = value): 16 hex digits via a lookup table
print_hex64:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    lea  r10, [numbuf + 16]
    mov  byte [r10], 0
    mov  r8d, 16
    lea  r9, [hexdigits]
.loop:
    mov  rax, rcx
    and  eax, 0xF
    mov  al, [r9 + rax]
    dec  r10
    mov  [r10], al
    shr  rcx, 4
    dec  r8d
    jnz  .loop
    mov  rcx, r10
    call print_str
    leave
    ret

; print_hex_bytes(RCX = pointer, RDX = byte count <= 38): "69C4E0D8..." in memory order
print_hex_bytes:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    lea  r10, [numbuf]          ; write pointer
    lea  r9, [hexdigits]
.next:
    test rdx, rdx
    jz   .out
    movzx eax, byte [rcx]
    mov  r8d, eax
    shr  eax, 4                 ; high nibble
    mov  al, [r9 + rax]
    mov  [r10], al
    and  r8d, 0xF               ; low nibble
    mov  al, [r9 + r8]
    mov  [r10 + 1], al
    add  r10, 2
    inc  rcx
    dec  rdx
    jmp  .next
.out:
    mov  byte [r10], 0
    lea  rcx, [numbuf]
    call print_str
    leave
    ret

; print_yesno(ECX = 0 or non-zero)
print_yesno:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32
    lea  rax, [no_str]
    lea  rdx, [yes_str]
    test ecx, ecx
    cmovnz rax, rdx             ; conditional move: pick "yes" when ECX != 0
    mov  rcx, rax
    call print_str
    leave
    ret

; cpuid_cache_bytes(ECX = cache level, EDX = type) -> RAX = size in bytes
; Walks CPUID leaf 4 sub-leaves until it finds the wanted cache.
; size = ways * partitions * line size * sets  (each field is stored minus 1)
cpuid_cache_bytes:
    push rbx                    ; CPUID clobbers RBX (non-volatile) -> save
    push rsi
    mov  esi, edx
    shl  esi, 8
    or   esi, ecx               ; ESI = (type << 8) | level  = key we look for
    xor  r9d, r9d               ; sub-leaf index
.next:
    mov  eax, 4
    mov  ecx, r9d
    cpuid
    mov  r10d, eax
    and  r10d, 0x1F             ; EAX[4:0] = cache type, 0 means "no more caches"
    jz   .none
    mov  r11d, eax
    shr  r11d, 5
    and  r11d, 7                ; EAX[7:5] = level
    shl  r10d, 8
    or   r10d, r11d             ; key of this sub-leaf
    cmp  r10d, esi
    jne  .advance
    mov  r10d, ebx
    shr  r10d, 22
    inc  r10d                   ; ways       = EBX[31:22] + 1
    mov  r11d, ebx
    shr  r11d, 12
    and  r11d, 0x3FF
    inc  r11d                   ; partitions = EBX[21:12] + 1
    imul r10, r11
    mov  r11d, ebx
    and  r11d, 0xFFF
    inc  r11d                   ; line size  = EBX[11:0]  + 1
    imul r10, r11
    mov  r11d, ecx              ; ECX = number of sets - 1
    inc  r11
    imul r10, r11
    mov  rax, r10
    jmp  .exit
.advance:
    inc  r9d
    jmp  .next
.none:
    xor  eax, eax
.exit:
    pop  rsi
    pop  rbx
    ret
