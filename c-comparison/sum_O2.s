	.file	"sum.c"
	.intel_syntax noprefix
	.text
	.p2align 4
	.globl	"sum"
	.def	"sum";	.scl	2;	.type	32;	.endef
	.seh_proc	"sum"
"sum":
	.seh_endprologue
	test	edx, edx
	jle	.L4
	mov	edx, edx
	xor	eax, eax
	lea	rdx, [rcx+rdx*4]
	.p2align 4
	.p2align 4
	.p2align 3
.L3:
	add	eax, DWORD PTR [rcx]
	add	rcx, 4
	cmp	rcx, rdx
	jne	.L3
	ret
	.p2align 4,,10
	.p2align 3
.L4:
	xor	eax, eax
	ret
	.seh_endproc
	.ident	"GCC: (MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r3) 16.2.0"
