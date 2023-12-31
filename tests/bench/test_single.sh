#!/usr/bin/env bash
source ../common.sh

# First check the C version actually works...
compile_lean_c_backend
exec_check "./$f.out" $(cat "$f.args")
diff_produced

# Then check the LLVM version
if lean_has_llvm_support; then
    echo "running LLVM program..."
    rm "./$f.out" || true
    compile_lean_llvm_backend
    exec_check "./$f.out" $(cat "$f.args")
    diff_produced
fi
