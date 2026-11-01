; =============================================================================
; aes.asm  -  Hardware cryptography: AES-128 with the CPU's AES-NI instructions,
;             plus hardware random numbers with RDRAND.
;
; The CPU has dedicated circuits for one AES round. We feed it the official test
; vector from FIPS-197 Appendix C.1, so the answer can be verified:
;     key        000102030405060708090a0b0c0d0e0f
;     plaintext  00112233445566778899aabbccddeeff
;     ciphertext 69c4e0d86a7b0430d8cdb78070b4c55a     <- must match exactly
;
; Concepts: XMM registers, AESKEYGENASSIST / AESENC / AESENCLAST / AESIMC /
;           AESDEC / AESDECLAST, NASM macros and %rep loops, PCMPEQB/PMOVMSKB
;           for 16-byte compares, RDRAND with retry on carry-flag failure.
; Build:    .\build.ps1 aes -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

section .data
key       db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
          db 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
plain     db 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
          db 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
expected  db 0x69, 0xC4, 0xE0, 0xD8, 0x6A, 0x7B, 0x04, 0x30
          db 0xD8, 0xCD, 0xB7, 0x80, 0x70, 0xB4, 0xC5, 0x5A

s_banner  db "=== aes.asm : AES-NI and RDRAND ===", 13, 10, 13, 10, 0
s_nocap   db "This CPU has no AES-NI.", 13, 10, 0
s_key     db "Key        : ", 0
s_plain   db "Plaintext  : ", 0
s_cipher  db "Ciphertext : ", 0
s_exp     db "Expected   : ", 0
s_match   db "Ciphertext matches the FIPS-197 test vector : ", 0
s_back    db "Decrypting gives back the plaintext          : ", 0
s_rand    db 13, 10, "Hardware random 64-bit values (RDRAND):", 13, 10, 0
s_rline   db "  0x", 0
s_rfail   db "  RDRAND failed or is unsupported", 13, 10, 0

section .bss
roundkeys   resb 176                    ; 11 round keys x 16 bytes (encryption)
cipher      resb 16
decrypted   resb 16

section .text

; -----------------------------------------------------------------------------
; key_step: one step of AES-128 key expansion.
;   In : XMM1 = previous round key,  XMM2 = result of AESKEYGENASSIST
;   Out: XMM1 = next round key
; Each 32-bit word of the new key = previous word XOR the word before it, which
; the three shift-and-XOR lines compute as a prefix XOR.
; -----------------------------------------------------------------------------
key_step:
    pshufd xmm2, xmm2, 0xFF             ; broadcast the top word of the assist result
    movdqa xmm3, xmm1
    pslldq xmm3, 4                      ; shift left by 4 BYTES (one word)
    pxor   xmm1, xmm3
    pslldq xmm3, 4
    pxor   xmm1, xmm3
    pslldq xmm3, 4
    pxor   xmm1, xmm3
    pxor   xmm1, xmm2
    ret

; EXPAND rcon, index: generate round key #index and store it
%macro EXPAND 2
    aeskeygenassist xmm2, xmm1, %1      ; %1 = round constant (immediate)
    call key_step
    movdqu [roundkeys + %2 * 16], xmm1
%endmacro

; -----------------------------------------------------------------------------
; same16(RCX = a, RDX = b) -> EAX = 1 if the two 16-byte blocks are equal
; -----------------------------------------------------------------------------
same16:
    movdqu xmm0, [rcx]
    movdqu xmm1, [rdx]
    pcmpeqb xmm0, xmm1                  ; each byte becomes 0xFF if equal, else 0
    pmovmskb eax, xmm0                  ; collect the 16 top bits into EAX
    cmp  eax, 0xFFFF
    sete al
    movzx eax, al
    ret

main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    mov  [rbp - 8], rbx                 ; CPUID clobbers RBX: save it

    call init_console
    lea  rcx, [s_banner]
    call print_str

    ; Guard: CPUID.1:ECX bit 25 = AES-NI
    mov  eax, 1
    cpuid
    mov  [rbp - 16], ecx                ; keep ECX for the RDRAND check later
    bt   ecx, 25
    jc   .have_aes
    lea  rcx, [s_nocap]
    call print_str
    jmp  .rdrand

.have_aes:
    ; ---- Key expansion: 10 round constants, doubling in GF(2^8) -----------------
    movdqu xmm1, [key]
    movdqu [roundkeys], xmm1            ; round key 0 is the key itself
    EXPAND 0x01, 1
    EXPAND 0x02, 2
    EXPAND 0x04, 3
    EXPAND 0x08, 4
    EXPAND 0x10, 5
    EXPAND 0x20, 6
    EXPAND 0x40, 7
    EXPAND 0x80, 8
    EXPAND 0x1B, 9
    EXPAND 0x36, 10

    ; ---- Encrypt one block ---------------------------------------------------------
    movdqu xmm0, [plain]
    movdqu xmm1, [roundkeys]
    pxor   xmm0, xmm1                   ; initial AddRoundKey
%assign i 1
%rep 9
    movdqu xmm1, [roundkeys + i * 16]
    aesenc xmm0, xmm1                   ; SubBytes+ShiftRows+MixColumns+AddRoundKey
%assign i i + 1
%endrep
    movdqu xmm1, [roundkeys + 160]
    aesenclast xmm0, xmm1               ; final round has no MixColumns
    movdqu [cipher], xmm0

    ; ---- Decrypt it again ------------------------------------------------------------
    ; Decryption uses the same keys in reverse order, with AESIMC (inverse
    ; MixColumns) applied to the middle ones.
    movdqu xmm0, [cipher]
    movdqu xmm1, [roundkeys + 160]
    pxor   xmm0, xmm1
%assign i 9
%rep 9
    movdqu xmm1, [roundkeys + i * 16]
    aesimc xmm1, xmm1
    aesdec xmm0, xmm1
%assign i i - 1
%endrep
    movdqu xmm1, [roundkeys]
    aesdeclast xmm0, xmm1
    movdqu [decrypted], xmm0

    ; ---- Report -------------------------------------------------------------------------
    lea  rcx, [s_key]
    call print_str
    lea  rcx, [key]
    mov  edx, 16
    call print_hex_bytes
    call print_crlf
    lea  rcx, [s_plain]
    call print_str
    lea  rcx, [plain]
    mov  edx, 16
    call print_hex_bytes
    call print_crlf
    lea  rcx, [s_cipher]
    call print_str
    lea  rcx, [cipher]
    mov  edx, 16
    call print_hex_bytes
    call print_crlf
    lea  rcx, [s_exp]
    call print_str
    lea  rcx, [expected]
    mov  edx, 16
    call print_hex_bytes
    call print_crlf
    call print_crlf

    lea  rcx, [s_match]
    call print_str
    lea  rcx, [cipher]
    lea  rdx, [expected]
    call same16
    mov  ecx, eax
    call print_yesno

    lea  rcx, [s_back]
    call print_str
    lea  rcx, [decrypted]
    lea  rdx, [plain]
    call same16
    mov  ecx, eax
    call print_yesno

    ; ---- RDRAND: CPUID.1:ECX bit 30 ---------------------------------------------------
.rdrand:
    lea  rcx, [s_rand]
    call print_str
    mov  eax, [rbp - 16]
    bt   eax, 30
    jnc  .norand
    mov  dword [rbp - 24], 3            ; print three values
.again:
    mov  ecx, 10                        ; RDRAND can transiently fail: retry up to 10 times
.retry:
    rdrand rax                          ; CF = 1 on success
    jc   .got
    dec  ecx
    jnz  .retry
.norand:
    lea  rcx, [s_rfail]
    call print_str
    jmp  .exit
.got:
    mov  [rbp - 32], rax
    lea  rcx, [s_rline]
    call print_str
    mov  rcx, [rbp - 32]
    call print_hex64
    call print_crlf
    dec  dword [rbp - 24]
    jnz  .again

.exit:
    mov  rbx, [rbp - 8]
    xor  ecx, ecx
    call ExitProcess
