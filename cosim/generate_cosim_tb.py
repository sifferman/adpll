#!/usr/bin/env python3
# Emit the ngspice testbench for the GATE-LEVEL adpll cosim: analog ring DCO (ngspice, extracted) + the
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
#   ./generate_cosim_tb.py --vvp adpll_bangbang_binary_gl --ring-subckt ring_dco_binary \
#       --corner typical --ref-mhz 200 --mul 12 --div 8 --post-div 1 > cosim_tb.spice

import argparse

TB_TEMPLATE = """\
* GATE-LEVEL ivlng cosim: ring DCO (ngspice) + synthesized gf180 loop (Icarus via d_cosim)
* ref={ref_mhz}MHz mul={mul} div={div} post_div={post_div} -> target F_DCO={target:.0f}MHz
* ngspice expands $PDK_ROOT in the .lib/.include FILE paths; the corner is a literal section name.
.include $PDK_ROOT/gf180mcuD/libs.tech/ngspice/design.ngspice
.lib $PDK_ROOT/gf180mcuD/libs.tech/ngspice/sm141064.ngspice {corner}
.include ring.spice
.temp 25
* KLU direct linear solver (ngspice is built with it): much faster matrix factorization than the
* default SPARSE 1.3 on this gate netlist -- same solution, just faster.
.options KLU
Vdd VDD 0 {vdd}
Vss VSS 0 0

* ---- digital loop (gate netlist, Icarus via ivlng) -- vector is decl-order, every bus MSB-first ----
.model loopm d_cosim (simulation="ivlng" sim_args=["{vvp}"])
a_loop [{ins}]
+      [{outs}] loopm

* ---- ring DCO (analog): VDD VSS clk_o enable_i tune_i[0..6] (subckt order is LSB-first) ----
X_dco VDD VSS dco_clk en_a tia0 tia1 tia2 tia3 tia4 tia5 tia6 {ring_subckt}
Cload dco_clk 0 2f

* ---- sources: ref clock, enable, reset (active-low), const-1/const-0 rails ----
* Enable the ring BEFORE releasing reset: the gf180 DFF model only resets on a clock edge taken while
* reset is asserted (its async-reset fires on a reset *edge*, which never happens since reset is low
* from t=0). The ref-clocked flops reset fine (ref runs from t=0), but the DCO-domain edge counter is
* clocked by dco_clk -- so the ring must be oscillating while reset is still low, or those flops stay X
* forever (and X poisons the whole loop). Hence enable at 20 ns, release reset at 60 ns.
Vref refa 0 PULSE(0 {vdd} 0 0.1n 0.1n {pw:.3f}n {tper:.3f}n)
Ven  en_a 0 PWL(0 0 20n 0 20.1n {vdd})
Vrst rsta 0 PWL(0 0 60n 0 60.1n {vdd})
Vone onea 0 {vdd}
Vzero zeroa 0 0

* ---- A/D + D/A bridges (ps delays so the adc tracks the ~hundreds-of-MHz DCO) ----
.model adcm adc_bridge (in_low={in_low:.3f} in_high={in_high:.3f} rise_delay=10p fall_delay=10p)
.model dacm dac_bridge (out_low=0 out_high={vdd:.3f} rise_delay=10p fall_delay=10p)
a_adc [refa rsta en_a dco_clk onea zeroa] [clk_d rst_d en_d dco_d d_one d_zero] adcm
a_dac_tune [tune_6 tune_5 tune_4 tune_3 tune_2 tune_1 tune_0] [tia6 tia5 tia4 tia3 tia2 tia1 tia0] dacm
a_dac_lock [lock_o] [lock_a] dacm

.save lock_a dco_clk
.tran {tstep_ps}p {tstop_ns}n uic
.control
run
* lock = first lock_a rise after reset releases (td past the 60ns reset window, so a startup
* transient can't be mistaken for lock); lock_held confirms it's still locked at the end (real,
* sustained lock -- not a momentary blip). The report treats the run as LOCKED only if both hold.
meas tran t_lock when v(lock_a)={vth:.3f} rise=1 td=65n
meas tran lock_held find v(lock_a) at={lock_check:.1f}n
.endc
.end"""


# PHASE-domain variant: the loop nulls phase, so there are TWO analog macros -- the ring DCO and the
# TDC (its flash delay line needs real cell delays, so it's extracted like the ring). The ring's clk_o
# drives the TDC's dco_clk_i in-analog; the TDC's phase_o[5:0] crosses back to the digital loop as a
# clean per-ref-cycle code. fcw_i (Q.TdcPhaseWidth) replaces mul/div.
# d_cosim vector (module-decl order, MSB-first): in  = clk rst enable fcw[23:0] post_div[7:0] tdc_phase[5:0] dco_clk
#                                                out = clk_o lock_o debug_dco_tune_o[6:0] debug_dco_clk_o
TB_TEMPLATE_PHASE = """\
* GATE-LEVEL ivlng cosim (PHASE): ring DCO + TDC (ngspice) + synthesized gf180 loop (Icarus, d_cosim)
* ref={ref_mhz}MHz fcw={fcw} (Q.6) -> target F_DCO={target:.0f}MHz
.include $PDK_ROOT/gf180mcuD/libs.tech/ngspice/design.ngspice
.lib $PDK_ROOT/gf180mcuD/libs.tech/ngspice/sm141064.ngspice {corner}
.include ring.spice
.include tdc.spice
.temp 25
* Trade accuracy for speed: the 63-tap TDC delay line switching at hundreds of MHz is the runtime
* bottleneck. Looser tolerances + bigger timesteps + device bypass cut the cost; the TDC phase is
* coarse (~2^PhaseWidth levels) so it tolerates this. (FLL deck keeps the defaults -- already fast.)
.options KLU reltol=1e-2 abstol=1e-8 vntol=1e-3 chgtol=1e-12 trtol=50 bypass=1 gmin=1e-9 itl4=200 maxord=2
Vdd VDD 0 {vdd}
Vss VSS 0 0

* ---- digital loop (gate netlist, Icarus via ivlng) -- vector is decl-order, every bus MSB-first ----
.model loopm d_cosim (simulation="ivlng" sim_args=["{vvp}"])
a_loop [{ins}]
+      [{outs}] loopm

* ---- ring DCO (analog): VDD VSS clk_o enable_i tune_i[0..6] ----
X_dco VDD VSS dco_clk ena tia0 tia1 tia2 tia3 tia4 tia5 tia6 {ring_subckt}
Cload dco_clk 0 2f

* ---- TDC (analog): extracted .subckt pin order is VDD VSS clk_i dco_clk_i period_valid_o
* ---- phase_o[0..5] rst_ni; samples the ring's phase at the ref edge. period_valid_o (pv_a) is
* ---- the TDC's self-reported coverage flag -- the loop leaves it unconnected, so it just dangles. ----
X_tdc VDD VSS refa dco_clk pv_a tpa0 tpa1 tpa2 tpa3 tpa4 tpa5 rsta {tdc_subckt}

* ---- sources: ref clock, enable, reset (active-low), const-1/const-0 rails ----
* Enable BEFORE releasing reset (see FLL deck): the gf180 DFF resets only on a clock edge taken while
* reset is low, and the DCO-domain edge counter / TDC flops are clocked by dco_clk -- so the ring must
* run while reset is asserted or those flops stay X forever. Enable at 20 ns, release reset at 60 ns.
Vref refa 0 PULSE(0 {vdd} 0 0.1n 0.1n {pw:.3f}n {tper:.3f}n)
Ven  ena  0 PWL(0 0 20n 0 20.1n {vdd})
Vrst rsta 0 PWL(0 0 60n 0 60.1n {vdd})
Vone onea 0 {vdd}
Vzero zeroa 0 0

* ---- A/D + D/A bridges (ps delays so the adc tracks the DCO + samples the TDC code) ----
.model adcm adc_bridge (in_low={in_low:.3f} in_high={in_high:.3f} rise_delay=10p fall_delay=10p)
.model dacm dac_bridge (out_low=0 out_high={vdd:.3f} rise_delay=10p fall_delay=10p)
a_adc [refa rsta ena dco_clk tpa5 tpa4 tpa3 tpa2 tpa1 tpa0 onea zeroa]
+     [clk_d rst_d en_d dco_d t_5 t_4 t_3 t_2 t_1 t_0 d_one d_zero] adcm
a_dac_tune [tune_6 tune_5 tune_4 tune_3 tune_2 tune_1 tune_0] [tia6 tia5 tia4 tia3 tia2 tia1 tia0] dacm
a_dac_lock [lock_o] [lock_a] dacm

.save lock_a dco_clk
.tran {tstep_ps}p {tstop_ns}n uic
.control
run
* lock = first lock_a rise after reset releases (td past the 60ns reset window, so a startup
* transient can't be mistaken for lock); lock_held confirms it's still locked at the end (real,
* sustained lock -- not a momentary blip). The report treats the run as LOCKED only if both hold.
meas tran t_lock when v(lock_a)={vth:.3f} rise=1 td=65n
meas tran lock_held find v(lock_a) at={lock_check:.1f}n
.endc
.end"""


def rails(val, n):
    """MSB-first constant-rail tokens (d_one/d_zero) for an n-bit value."""
    return ["d_one" if (val >> i) & 1 else "d_zero" for i in range(n - 1, -1, -1)]


def main():
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
    # phase-domain mode (TDC second analog macro + fcw instead of mul/div)
    ap.add_argument("--phase", action="store_true", help="phase-domain config (TDC macro + fcw)")
    ap.add_argument("--fcw", type=int, default=427, help="frequency control word, Q.6 (phase mode)")
    ap.add_argument("--tdc-subckt", default="adpll_tdc_flash", help=".subckt name of the extracted TDC")
    a = ap.parse_args()

    tper = 1000.0 / a.ref_mhz
    # adc_bridge thresholds: use a SINGLE threshold (in_low == in_high == vdd/2), not a wide band. A
    # wide band makes the bridge emit X while a signal slews through it, and Icarus treats 0->x->1 as
    # TWO posedges -> the DCO edge counter double-counts (the ring would lock at half the target). A
    # single threshold digitizes cleanly: one 0->1 per real edge.
    common = dict(ref_mhz=a.ref_mhz, corner=a.corner, vvp=a.vvp, vdd=a.vdd, ring_subckt=a.ring_subckt,
                  pw=tper / 2.0 - 0.1, tper=tper, in_low=a.vdd / 2, in_high=a.vdd / 2,
                  vth=a.vdd / 2, tstep_ps=a.tstep_ps, tstop_ns=a.tstop_ns,
                  lock_check=a.tstop_ns - 20.0)
    outs = ["clk_o", "lock_o"] + [f"tune_{i}" for i in range(6, -1, -1)] + ["debug_dco_clk_o"]

    if a.phase:
        ins = (["clk_d", "rst_d", "en_d"] + rails(a.fcw, 24) + rails(a.post_div, 8)
               + [f"t_{i}" for i in range(5, -1, -1)] + ["dco_d"])
        print(TB_TEMPLATE_PHASE.format(fcw=a.fcw, target=a.fcw / 64.0 * a.ref_mhz,
              ins=" ".join(ins), outs=" ".join(outs), tdc_subckt=a.tdc_subckt, **common))
    else:
        ins = ["clk_d", "rst_d", "en_d"] + rails(a.mul, 8) + rails(a.div, 4) + rails(a.post_div, 8) + ["dco_d"]
        print(TB_TEMPLATE.format(mul=a.mul, div=a.div, post_div=a.post_div,
              target=a.mul / a.div * a.ref_mhz, ins=" ".join(ins), outs=" ".join(outs), **common))


if __name__ == "__main__":
    main()
