#!/usr/bin/env bash
# Closed-loop mixed-signal cosim of one adpll config at one corner:
#   ring DCO in ngspice (extracted) + digital loop in Verilog (d_cosim).
# Usage (inside the nix devshell, PDK enabled):  run_cosim.sh <adpll_filter_dco> <corner>
#   env: PDK PDK_ROOT SCL  (as for `make dco-spice`)
# Writes cosim_<config>_<corner>.txt and exits non-zero if the loop never locks.
#
# The deck (adpll_cosim_tb.spice) is static: ngspice expands $PDK_ROOT (the standard PDK env var) in
# its .include paths. The two run-specific inputs are generated here -- corner.lib (the .lib section,
# which can't be an env var) and ring.spice (the hardened ring, .subckt renamed to the fixed "dco").
#
# EXPERIMENTAL: a cell locks only if the baked mul/div (12/8 -> 300 MHz @ 200 MHz ref) is reachable
# by that DCO at that corner; coarse/multi-mode rings may need per-config mul/div tuning.
set -euo pipefail
cd "$(dirname "$0")"
CFG="$1"; CORNER="${2:-typical}"
rest="${CFG#adpll_}"; FILTER="${rest%%_*}"; DCO="ring_dco_${rest#*_}"
case "$FILTER" in
  linear)    DEF="+define+FILTER_PI";        FF=pi        ;;
  gearshift) DEF="+define+FILTER_GEARSHIFT"; FF=gearshift ;;
  *)         DEF="";                         FF=bangbang  ;;
esac
export PDK_ROOT                                                   # ngspice expands $PDK_ROOT in the deck
NG="$PDK_ROOT/gf180mcuD/libs.tech/ngspice"
GCCLIB=$(ls -d /nix/store/*gcc-14*-lib/lib 2>/dev/null | head -1)
[ -f "$NG/sm141064.ngspice" ] || { echo "PDK models not at $NG (PDK_ROOT=$PDK_ROOT)"; exit 1; }

echo "== harden $DCO (ring) =="
librelane ../librelane/ring_dco.yaml --pdk "$PDK" --pdk-root "$PDK_ROOT" --scl "$SCL" -c DESIGN_NAME="$DCO"
RING=$(ls -td ../librelane/runs/*/final/spice/"$DCO".spice | head -1)
sed "s/$DCO/dco/g" "$RING" > ring.spice                          # rename .subckt -> fixed "dco"
echo ".lib \$PDK_ROOT/gf180mcuD/libs.tech/ngspice/sm141064.ngspice $CORNER" > corner.lib  # literal corner, env path

echo "== build loop .so ($FILTER) =="
./build_cosim_so.sh adpll_loop $DEF adpll_loop_cosim.sv \
  ../rtl/adpll_freq_detector.sv ../rtl/adpll_freq_counter.sv \
  ../rtl/loop_filter/adpll_loop_filter_$FF.sv ../rtl/adpll_lock_detector.sv

echo "== ngspice cosim ($CFG @ $CORNER) =="
out="cosim_${CFG}_${CORNER}.txt"
env -u DISPLAY LD_LIBRARY_PATH="$GCCLIB" ngspice -b adpll_cosim_tb.spice 2>&1 \
  | tee "ngspice_${CFG}_${CORNER}.log" | grep -aiE "t_lock|lock=1" || true
if t=$(grep -aoE "t_lock *= *[0-9.eE+-]+" "ngspice_${CFG}_${CORNER}.log" | head -1) && [ -n "$t" ]; then
  echo "$CFG @ $CORNER: LOCKED ($t)" | tee "$out"
else
  echo "$CFG @ $CORNER: NO-LOCK" | tee "$out"; exit 1
fi
