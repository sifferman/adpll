#!/usr/bin/env bash
# Build an ngspice d_cosim shared library from Verilog via Verilator.
# Run inside the nix devshell.  Usage: build_cosim_so.sh <out_base> <top.v> [more.v ...]
#
# Mirrors ngspice's vlnggen, but driven directly (vlnggen wants X / ~/tmp / interactive ngspice).
# Builds a --timing model: the d_cosim shim's WITH_TIMING path advances queued events, which a
# multi-clock design (ref + DCO) needs.  verilated_timing.o is folded into verilated.o in v5.046.
set -euo pipefail
SRC=$(ls -d /nix/store/*ngspice*/share/ngspice/scripts/src 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "could not find ngspice scripts/src"; exit 1; }
OUT="$1"; shift
OBJ="${OUT}_obj_dir"
here=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OBJ"
verilator --Mdir "$OBJ" --prefix Vlng -Wno-fatal --timing --cc "$@"                  # phase 1: Vlng.h
python3 "$here/gen_headers.py" "$OBJ/Vlng.h" "$OBJ"                                   # phase 2: port headers
verilator --Mdir "$OBJ" --prefix Vlng -Wno-fatal --timing \
  --CFLAGS "-fpic -DWITH_TIMING -I$SRC -I$OBJ" \
  --cc --build --exe "$SRC/verilator_main.cpp" "$SRC/verilator_shim.cpp" "$@"         # phase 3: shim
g++ -shared -fPIC -o "${OUT}.so" "$OBJ/verilator_shim.o" "$OBJ/verilated.o" \
  "$OBJ/verilated_threads.o" "$OBJ"/Vlng__ALL.a -pthread -latomic                     # phase 4: link (no main)
echo "built $(pwd)/${OUT}.so   (ports: see $OBJ/inputs.h, $OBJ/outputs.h -- d_cosim vector order!)"
