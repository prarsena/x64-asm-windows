	.file	"sum.c"
	.intel_syntax noprefix
	.text
	.p2align 4
	.globl	"sum"
	.def	"sum";	.scl	2;	.type	32;	.endef
	.seh_proc	"sum"
"sum":
	.seh_endprologue
	mov	r10, rcx
	mov	ecx, edx
	test	edx, edx
	jle	.L6
	lea	eax, -1[rdx]
	vpxor	xmm0, xmm0, xmm0
	cmp	eax, 6
	jbe	.L7
	mov	r8d, edx
	mov	rax, r10
	shr	r8d, 3
	mov	edx, r8d
	sal	rdx, 5
	add	rdx, r10
	.p2align 4
	.p2align 4
	.p2align 3
.L4:
	vpaddd	ymm0, ymm0, YMMWORD PTR [rax]
	add	rax, 32
	cmp	rdx, rax
	jne	.L4
	vextracti128	xmm1, ymm0, 0x1
	lea	eax, 0[0+r8*8]
	vpaddd	xmm1, xmm1, xmm0
	vpsrldq	xmm0, xmm1, 8
	vpaddd	xmm0, xmm1, xmm0
	vpsrldq	xmm2, xmm0, 4
	vpaddd	xmm0, xmm0, xmm2
	vmovd	r9d, xmm0
	cmp	ecx, eax
	je	.L9
	mov	edx, eax
	vzeroupper
.L3:
	mov	r8d, ecx
	sub	r8d, eax
	lea	r9d, -1[r8]
	cmp	r9d, 2
	jbe	.L5
	vpaddd	xmm1, xmm1, XMMWORD PTR [r10+rax*4]
	mov	eax, r8d
	and	eax, -4
	and	r8d, 3
	vpsrldq	xmm0, xmm1, 8
	vpaddd	xmm1, xmm1, xmm0
	vpsrldq	xmm0, xmm1, 4
	vpaddd	xmm0, xmm1, xmm0
	vmovd	r9d, xmm0
	je	.L1
	add	edx, eax
.L5:
	mov	eax, edx
	lea	r8d, 1[rdx]
	vmovd	xmm1, DWORD PTR [r10+rax*4]
	vpaddd	xmm0, xmm0, xmm1
	vmovd	r9d, xmm0
	cmp	ecx, r8d
	jle	.L1
	vmovd	xmm1, DWORD PTR 4[r10+rax*4]
	add	edx, 2
	vpaddd	xmm0, xmm0, xmm1
	vmovd	r9d, xmm0
	cmp	ecx, edx
	jle	.L1
	vmovd	xmm1, DWORD PTR 8[r10+rax*4]
	vpaddd	xmm0, xmm0, xmm1
	vmovd	r9d, xmm0
.L1:
	mov	eax, r9d
	ret
	.p2align 4,,10
	.p2align 3
.L6:
	xor	r9d, r9d
	mov	eax, r9d
	ret
	.p2align 4,,10
	.p2align 3
.L9:
	mov	eax, r9d
	vzeroupper
	ret
.L7:
	vmovdqa	xmm1, xmm0
	xor	eax, eax
	vpxor	xmm0, xmm0, xmm0
	xor	edx, edx
	jmp	.L3
	.seh_endproc
	.ident	"GCC: (MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r3) 16.2.0"
