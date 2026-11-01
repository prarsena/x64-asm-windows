; =============================================================================
; galaxybook.asm  -  Ask Windows (and the firmware) about THIS Samsung laptop.
;
; Uses these Windows APIs directly from assembly:
;   GetSystemFirmwareTable('RSMB')  raw SMBIOS tables written by Samsung's BIOS
;   RegGetValueA                    BIOS strings Windows cached in the registry
;   GetSystemPowerStatus            battery / AC state
;   EnumDisplaySettingsA            the panel's real mode (not DPI-scaled)
;   GetPhysicallyInstalledSystemMemory  RAM installed (from SMBIOS), not just usable
;
; The SMBIOS "serial number" field is intentionally never printed.
;
; Concepts: parsing a binary table with variable-length records, string tables
;           indexed by number, 7-argument API call (stack arguments), structs.
; Build:    .\build.ps1 galaxybook -Run
; =============================================================================

default rel
bits 64
%include "common.inc"
global main

extern GetSystemFirmwareTable
extern GetSystemPowerStatus
extern EnumDisplaySettingsA
extern RegGetValueA
extern GetPhysicallyInstalledSystemMemory

FW_RSMB          equ 0x52534D42         ; 'RSMB' (raw SMBIOS) as a DWORD
SMB_BUF_SIZE     equ 65536
HKLM             equ 0xFFFFFFFF80000002 ; HKEY_LOCAL_MACHINE (a sign-extended pseudo-handle)
RRF_RT_REG_SZ    equ 2
ENUM_CURRENT     equ -1

; Print one SMBIOS string field: SMB label, byte offset of the string index
%macro SMB 2
    mov  rdx, [rbp - 16]                ; current SMBIOS structure
    lea  rcx, [%1]
    mov  r8d, %2
    call print_smb
%endmacro

section .data
s_banner  db "=== galaxybook.asm : Samsung Galaxy Book6 firmware & hardware ===", 13, 10, 13, 10, 0
s_smbver  db "SMBIOS table version      : ", 0
s_dot     db ".", 0
s_sect1   db 13, 10, "-- Type 0: BIOS --", 13, 10, 0
s_sect2   db 13, 10, "-- Type 1: System --", 13, 10, 0
s_sect3   db 13, 10, "-- Type 2: Baseboard --", 13, 10, 0
s_vendor  db "  Vendor        : ", 0
s_bver    db "  BIOS version  : ", 0
s_bdate   db "  Release date  : ", 0
s_manu    db "  Manufacturer  : ", 0
s_prod    db "  Product name  : ", 0
s_sver    db "  Version       : ", 0
s_sku     db "  SKU number    : ", 0
s_family  db "  Family        : ", 0
s_board   db "  Board model   : ", 0
s_nosmb   db "GetSystemFirmwareTable failed", 13, 10, 0
s_empty   db "(none)", 0

s_regsec  db 13, 10, "-- Registry: HKLM\HARDWARE\DESCRIPTION\System\BIOS --", 13, 10, 0
s_reg1    db "  SystemProductName : ", 0
s_reg2    db "  SystemFamily      : ", 0
s_reg3    db "  BIOSVersion       : ", 0
s_unavail db "(unavailable)", 13, 10, 0
k_bios    db "HARDWARE\DESCRIPTION\System\BIOS", 0
v_prod    db "SystemProductName", 0
v_fam     db "SystemFamily", 0
v_biosver db "BIOSVersion", 0

s_powsec  db 13, 10, "-- Battery (GetSystemPowerStatus) --", 13, 10, 0
s_ac      db "  On AC power       : ", 0
s_pct     db "  Charge            : ", 0
s_pctu    db " %", 13, 10, 0
s_charge  db "  Charging          : ", 0
s_unknown db "unknown", 13, 10, 0

s_dispsec db 13, 10, "-- Display (EnumDisplaySettingsA) --", 13, 10, 0
s_mode    db "  Current mode      : ", 0
s_by      db " x ", 0
s_at      db " @ ", 0
s_hz      db " Hz", 13, 10, 0

s_memsec  db 13, 10, "-- Memory --", 13, 10, 0
s_ram     db "  Installed RAM (SMBIOS): ", 0
s_mib     db " MiB", 13, 10, 0

section .bss
smbios      resb SMB_BUF_SIZE
regbuf      resb 256
powerstat   resb 16                     ; SYSTEM_POWER_STATUS is 12 bytes
devmode     resb 160                    ; DEVMODEA is 156 bytes
ram_kib     resq 1

section .text

; -----------------------------------------------------------------------------
; smbios_string(RDX = structure pointer, R9D = 1-based string index) -> RAX = text
; SMBIOS stores text AFTER the fixed-size part of each structure as a list of
; NUL-terminated strings, and fields refer to them by number (0 = no string).
; Leaf function: uses RAX, R9 only.
; -----------------------------------------------------------------------------
smbios_string:
    movzx eax, byte [rdx + 1]           ; byte 1 of every structure = its formatted length
    add  rax, rdx                       ; RAX -> first string
    test r9d, r9d
    jz   .empty
.next:
    dec  r9d
    jz   .found
.scan:
    cmp  byte [rax], 0
    je   .skip_nul
    inc  rax
    jmp  .scan
.skip_nul:
    inc  rax                            ; step over the terminator -> next string
    jmp  .next
.found:
    ret
.empty:
    lea  rax, [s_empty]
    ret

; print_smb(RCX = label, RDX = structure, R8D = offset of the string-index byte)
print_smb:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    movzx r9d, byte [rdx + r8]          ; the string index stored in the structure
    call smbios_string                  ; RCX (the label) is untouched
    mov  [rbp - 16], rax
    call print_str                      ; print the label
    mov  rcx, [rbp - 16]
    call print_str                      ; print the string itself
    call print_crlf
    leave
    ret

; print_reg(RCX = label, RDX = registry value name)  - reads a REG_SZ under HKLM
print_reg:
    push rbp
    mov  rbp, rsp
    sub  rsp, 80
    mov  [rbp - 8], rdx
    call print_str                      ; label
    mov  dword [rbp - 16], 256          ; in: buffer size, out: bytes written
    mov  byte [regbuf], 0
    mov  rcx, HKLM                      ; arg1 hKey
    lea  rdx, [k_bios]                  ; arg2 subkey
    mov  r8, [rbp - 8]                  ; arg3 value name
    mov  r9d, RRF_RT_REG_SZ             ; arg4 flags: only accept strings
    mov  qword [rsp + 32], 0            ; arg5 pdwType  = NULL
    lea  rax, [regbuf]
    mov  [rsp + 40], rax                ; arg6 pvData   (stack argument)
    lea  rax, [rbp - 16]
    mov  [rsp + 48], rax                ; arg7 pcbData  (stack argument)
    call RegGetValueA
    test eax, eax                       ; ERROR_SUCCESS == 0
    jnz  .fail
    lea  rcx, [regbuf]
    call print_str
    call print_crlf
    jmp  .done
.fail:
    lea  rcx, [s_unavail]
    call print_str
.done:
    leave
    ret

main:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96
    ; Frame: [rbp-8] SMBIOS bytes returned  [rbp-16] current structure
    ;        [rbp-24] end of table
    call init_console
    lea  rcx, [s_banner]
    call print_str

    ; ---- Read the raw SMBIOS table ------------------------------------------------
    mov  ecx, FW_RSMB
    xor  edx, edx                       ; table id 0
    lea  r8, [smbios]
    mov  r9d, SMB_BUF_SIZE
    call GetSystemFirmwareTable         ; returns number of bytes copied (0 = failure)
    test eax, eax
    jz   .smb_fail
    ; Header: [0]=used20 [1]=major [2]=minor [3]=dmi rev [4..7]=table length [8..]=data
    mov  edx, [smbios + 4]              ; length of the table data
    lea  rax, [smbios + 8]
    mov  [rbp - 16], rax                ; first structure
    add  rax, rdx
    mov  [rbp - 24], rax                ; end of table

    lea  rcx, [s_smbver]
    call print_str
    movzx ecx, byte [smbios + 1]
    call print_udec
    lea  rcx, [s_dot]
    call print_str
    movzx ecx, byte [smbios + 2]
    call print_dec

    ; ---- Walk the structures --------------------------------------------------------
    ; Each: [0]=type [1]=formatted length [2..3]=handle ... then strings ending in 00 00
.walk:
    mov  rax, [rbp - 16]
    cmp  rax, [rbp - 24]
    jae  .after_smbios
    movzx ecx, byte [rax]
    cmp  ecx, 127                       ; type 127 = end of table
    je   .after_smbios
    test ecx, ecx
    jz   .type0
    cmp  ecx, 1
    je   .type1
    cmp  ecx, 2
    je   .type2
    jmp  .advance

.type0:
    lea  rcx, [s_sect1]
    call print_str
    SMB  s_vendor, 4
    SMB  s_bver, 5
    SMB  s_bdate, 8
    jmp  .advance
.type1:
    lea  rcx, [s_sect2]
    call print_str
    SMB  s_manu, 4
    SMB  s_prod, 5
    SMB  s_sver, 6
    ; offset 7 is the serial number: deliberately skipped
    mov  rax, [rbp - 16]
    cmp  byte [rax + 1], 0x1B           ; SKU / family exist only in structures >= 27 bytes
    jb   .advance
    SMB  s_sku, 0x19
    SMB  s_family, 0x1A
    jmp  .advance
.type2:
    lea  rcx, [s_sect3]
    call print_str
    SMB  s_manu, 4
    SMB  s_board, 5

.advance:
    mov  rax, [rbp - 16]
    movzx ecx, byte [rax + 1]
    add  rax, rcx                       ; skip the formatted area
.strings:
    cmp  word [rax], 0                  ; two NULs in a row end the string area
    je   .strings_end
    inc  rax
    jmp  .strings
.strings_end:
    add  rax, 2
    mov  [rbp - 16], rax
    jmp  .walk

.smb_fail:
    lea  rcx, [s_nosmb]
    call print_str

.after_smbios:
    ; ---- Same facts again, from the registry ---------------------------------------
    lea  rcx, [s_regsec]
    call print_str
    lea  rcx, [s_reg1]
    lea  rdx, [v_prod]
    call print_reg
    lea  rcx, [s_reg2]
    lea  rdx, [v_fam]
    call print_reg
    lea  rcx, [s_reg3]
    lea  rdx, [v_biosver]
    call print_reg

    ; ---- Battery -------------------------------------------------------------------------
    ; SYSTEM_POWER_STATUS: [0]=ACLineStatus [1]=BatteryFlag [2]=BatteryLifePercent
    lea  rcx, [s_powsec]
    call print_str
    lea  rcx, [powerstat]
    call GetSystemPowerStatus
    lea  rcx, [s_ac]
    call print_str
    movzx ecx, byte [powerstat]
    cmp  ecx, 255                       ; 255 = unknown
    je   .ac_unknown
    call print_yesno                    ; 1 = online, 0 = offline
    jmp  .pct
.ac_unknown:
    lea  rcx, [s_unknown]
    call print_str
.pct:
    lea  rcx, [s_pct]
    call print_str
    movzx ecx, byte [powerstat + 2]
    cmp  ecx, 255
    je   .pct_unknown
    call print_udec
    lea  rcx, [s_pctu]
    call print_str
    jmp  .charging
.pct_unknown:
    lea  rcx, [s_unknown]
    call print_str
.charging:
    lea  rcx, [s_charge]
    call print_str
    movzx ecx, byte [powerstat + 1]
    and  ecx, 8                         ; BatteryFlag bit 3 = charging
    call print_yesno

    ; ---- Display ----------------------------------------------------------------------------
    ; DEVMODEA: dmSize at +36 (WORD), dmPelsWidth +108, dmPelsHeight +112, dmDisplayFrequency +120
    lea  rcx, [s_dispsec]
    call print_str
    mov  word [devmode + 36], 156       ; the caller must fill in dmSize
    xor  ecx, ecx                       ; NULL = the primary display device
    mov  edx, ENUM_CURRENT
    lea  r8, [devmode]
    call EnumDisplaySettingsA
    lea  rcx, [s_mode]
    call print_str
    mov  ecx, [devmode + 108]
    call print_udec
    lea  rcx, [s_by]
    call print_str
    mov  ecx, [devmode + 112]
    call print_udec
    lea  rcx, [s_at]
    call print_str
    mov  ecx, [devmode + 120]
    call print_udec
    lea  rcx, [s_hz]
    call print_str

    ; ---- Memory ---------------------------------------------------------------------------------
    lea  rcx, [s_memsec]
    call print_str
    lea  rcx, [ram_kib]
    call GetPhysicallyInstalledSystemMemory
    lea  rcx, [s_ram]
    call print_str
    mov  rcx, [ram_kib]
    shr  rcx, 10                        ; KiB -> MiB
    call print_udec
    lea  rcx, [s_mib]
    call print_str

    xor  ecx, ecx
    call ExitProcess
