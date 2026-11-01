/* sum.c - the same job as simd.asm, written in C.
 * Compile to assembly instead of an executable to see what the compiler wrote:
 *   gcc -O2 -S -masm=intel sum.c -o sum_O2.s
 *   gcc -O3 -mavx2 -S -masm=intel sum.c -o sum_O3_avx2.s
 */
int sum(const int *a, int n)
{
    int total = 0;
    for (int i = 0; i < n; i++)
        total += a[i];
    return total;
}
