; =============================================================================
; hello.asm  -  Your first Windows x64 assembly program (NASM syntax)
;
; What it does : prints a greeting to the console, then exits with code 0.
; How it works : no C runtime. We call three Windows API functions in
;                kernel32.dll directly: GetStdHandle, WriteFile and ExitProcess.
;
; Build (see README.md):
;   nasm -f win64 hello.asm -o hello.obj
;   gcc hello.obj -o hello.exe -nostartfiles -Wl,-e,main -lkernel32
; =============================================================================

default rel                     ; use RIP-relative addressing for data (required on x64)
bits 64

global main                     ; entry point symbol, exported to the linker

; Functions that live in kernel32.dll. The linker resolves them via the import library.
extern GetStdHandle
extern WriteFile
extern ExitProcess

STD_OUTPUT_HANDLE equ -11       ; constant from winbase.h (a 32-bit signed -11)

section .data                   ; initialised, read/write data
msg     db "Hello from x64 assembly on Windows!", 13, 10   ; 13,10 = CR,LF
msg_len equ $ - msg             ; assembler computes the length: current address - start

section .bss                    ; zero-initialised data (takes no space in the file)
written resd 1                  ; reserve 1 dword: WriteFile stores bytes-written here

section .text                   ; executable code
main:
    ; --- Stack setup -------------------------------------------------------
    ; Windows x64 calling convention rules:
    ;   * Integer/pointer args go in RCX, RDX, R8, R9 (then on the stack).
    ;   * The caller must reserve 32 bytes of "shadow space" above the return address.
    ;   * RSP must be 16-byte aligned at the moment of every CALL.
    ; On entry RSP is 8 mod 16 (the return address was just pushed), so we
    ; subtract 32 shadow + 8 (5th argument of WriteFile) + 16 spare = 56, which is
    ; also 8 mod 16, bringing RSP back to 16-byte alignment.
    sub rsp, 56

    ; --- HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE) ---------------------
    mov ecx, STD_OUTPUT_HANDLE  ; 1st arg -> RCX (writing ECX zero-extends into RCX)
    call GetStdHandle           ; return value (the handle) comes back in RAX

    ; --- WriteFile(h, msg, msg_len, &written, NULL) -----------------------
    mov rcx, rax                ; arg1: hFile
    lea rdx, [msg]              ; arg2: pointer to the buffer (LEA = load effective address)
    mov r8d, msg_len            ; arg3: number of bytes to write
    lea r9, [written]           ; arg4: pointer to a DWORD receiving the count
    mov qword [rsp + 32], 0     ; arg5: lpOverlapped = NULL, lives at [RSP+32] just above shadow space
    call WriteFile

    ; --- ExitProcess(0) -----------------------------------------------------
    xor ecx, ecx                ; XOR reg,reg is the idiomatic way to set 0
    call ExitProcess            ; never returns
