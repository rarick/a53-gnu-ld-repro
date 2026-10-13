#!/usr/bin/env bash
# Does the C compiler driver (the linker driver rustc uses) add
# --fix-cortex-a53-843419 on its own?
cd /tmp && echo 'int main(void){return 0;}' > t.c
gcc --version | head -1
gcc -v 2>&1 | tr ' ' '\n' | grep -i cortex
gcc -Q --help=target | grep -i 'fix-cortex'
for f in "" -mno-fix-cortex-a53-843419; do
  printf 'gcc %-28s -> ld receives --fix-cortex-a53-843419: ' "${f:-(default)}"
  gcc $f -### t.c -o t 2>&1 | tr ' ' '\n' | grep -c -- '--fix-cortex-a53-843419'
done
