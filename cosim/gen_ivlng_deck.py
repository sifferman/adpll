#!/usr/bin/env python3
# Emit the ngspice deck for the GATE-LEVEL adpll cosim: analog ring DCO (ngspice, extracted) + the
# synthesized gf180 loop run in Icarus Verilog through ngspice's d_cosim (the `ivlng` shim).
#
# The synthesized loop's port interface is FIXED -- all 12 adpll_<filter>_<dco> wrappers share it, and
# the Makefile pins the synth shrink, so the gate netlist's port widths never change. Hence the d_cosim
# port vector is a constant and there is nothing to parse: only mul/div/post_div (tied to rails), the
# ring subckt name, the corner, and the reference period vary between runs.
#
# d_cosim vector -- module-declaration order, every bus MSB-first (verified empirically vs ivlng):
#   in : clk_i rst_ni enable_i  ref_mul_i[7:0] ref_div_i[3:0] post_div_i[7:0]  dco_clk
#   out: clk_o lock_o  debug_dco_tune_o[6:0]  debug_dco_clk_o
# The ring's tune_i is LSB-first in its .subckt, so the tune dac maps tune_6..tune_0 -> tia6..tia0 and
# the ring is wired tia0..tia6.
#
#   ./gen_ivlng_deck.py --vvp adpll_bangbang_binary_gl --ring-subckt ring_dco_binary \
#       --corner typical --ref-mhz 200 --mul 12 --div 8 --post-div 1 > deck.spice

import argparse


def rails(val, n):
    """MSB-first constant-rail tokens (d_one/d_zero) for an n-bit value."""
    return ["d_one" if (val >> i) & 1 else "d_zero" for i in range(n - 1, -1, -1)]


ap = argparse.ArgumentParser()
ap.add_argument("--vvp", required=True, help="compiled Icarus vvp (loop + cell models), in build/")
ap.add_argument("--ring-subckt", required=True, help=".subckt name of the extracted ring (ring.spice)")
ap.add_argument("--corner", default="typical", help="sm141064.ngspice section (typical/ss/ff)")
ap.add_argument("--ref-mhz", type=float, default=200.0)
ap.add_argument("--mul", type=int, default=12)
ap.add_argument("--div", type=int, default=8)
ap.add_argument("--post-div", type=int, default=1)
ap.add_argument("--vdd", type=float, default=3.3)
ap.add_argument("--tstop-ns", type=float, default=1000.0)
ap.add_argument("--tstep-ps", type=float, default=20.0)
a = ap.parse_args()

ins = ["clk_d", "rst_d", "en_d"] + rails(a.mul, 8) + rails(a.div, 4) + rails(a.post_div, 8) + ["dco_d"]
outs = ["clk_o", "lock_o"] + [f"tune_{i}" for i in range(6, -1, -1)] + ["debug_dco_clk_o"]
v = a.vdd
tper = 1000.0 / a.ref_mhz
thi = tper / 2.0

print(f"""* GATE-LEVEL ivlng cosim: ring DCO (ngspice) + synthesized gf180 loop (Icarus via d_cosim)
* ref={a.ref_mhz}MHz mul={a.mul} div={a.div} post_div={a.post_div} -> target F_DCO={a.mul/a.div*a.ref_mhz:.0f}MHz
* ngspice expands $PDK_ROOT in the .lib/.include FILE paths; the corner is a literal section name.
.include $PDK_ROOT/gf180mcuD/libs.tech/ngspice/design.ngspice
.lib $PDK_ROOT/gf180mcuD/libs.tech/ngspice/sm141064.ngspice {a.corner}
.include ring.spice
.temp 25
Vdd VDD 0 {v}
Vss VSS 0 0

* ---- digital loop (gate netlist, Icarus via ivlng) -- vector is decl-order, every bus MSB-first ----
.model loopm d_cosim (simulation="ivlng" sim_args=["{a.vvp}"])
a_loop [{' '.join(ins)}]
+      [{' '.join(outs)}] loopm

* ---- ring DCO (analog): VDD VSS clk_o enable_i tune_i[0..6] (subckt order is LSB-first) ----
X_dco VDD VSS dco_clk en_a tia0 tia1 tia2 tia3 tia4 tia5 tia6 {a.ring_subckt}
Cload dco_clk 0 2f

* ---- sources: ref clock, reset (active-low), enable, and the const-1/const-0 rails ----
Vref refa 0 PULSE(0 {v} 0 0.1n 0.1n {thi-0.1:.3f}n {tper:.3f}n)
Vrst rsta 0 PWL(0 0 30n 0 30.1n {v})
Ven  en_a 0 PWL(0 0 40n 0 40.1n {v})
Vone onea 0 {v}
Vzero zeroa 0 0

* ---- A/D + D/A bridges (ps delays so the adc tracks the ~hundreds-of-MHz DCO) ----
.model adcm adc_bridge (in_low={v/3:.3f} in_high={2*v/3:.3f} rise_delay=10p fall_delay=10p)
.model dacm dac_bridge (out_low=0 out_high={v:.3f} rise_delay=10p fall_delay=10p)
a_adc [refa rsta en_a dco_clk onea zeroa] [clk_d rst_d en_d dco_d d_one d_zero] adcm
a_dac_tune [tune_6 tune_5 tune_4 tune_3 tune_2 tune_1 tune_0] [tia6 tia5 tia4 tia3 tia2 tia1 tia0] dacm
a_dac_lock [lock_o] [lock_a] dacm

.save lock_a dco_clk
.tran {a.tstep_ps}p {a.tstop_ns}n uic
.control
run
meas tran t_lock when v(lock_a)={v/2:.3f} rise=1
.endc
.end""")
