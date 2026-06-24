#!/usr/bin/env python3
# Generate the ngspice deck for the GATE-LEVEL co-simulation of one adpll config:
#   analog ring DCO (ngspice, extracted transistors) + the digital loop as a GATE netlist
#   (gf180 cells) run in Icarus Verilog through ngspice's d_cosim XSPICE model via the `ivlng`
#   shim. Unlike the Verilator POC this loop is the *real synthesized gate netlist* derived from
#   the adpll wrapper by the Makefile's yosys step (ring black-boxed, its clk_o promoted to the top
#   input `dco_clk`, tune kept as `debug_dco_tune_o`) -- so there is no hand-written loop top.
#
# The d_cosim port vector is [<inputs>][<outputs>] in the module's port-declaration order, and
# each bus is MSB-first (verified empirically against ivlng: first bracket slot = MSB, in and out).
# mul/div/post_div are ports on the netlist (the wrapper does not bake them), so we tie their bits
# to constant digital nodes here; the ring's tune_i order is read from its .subckt line.
#
#   ./gen_ivlng_deck.py --netlist adpll_loop_gl.v --module adpll_bangbang_binary \
#       --vvp adpll_loop_gl --ring ring.spice --ring-subckt ring_dco_binary \
#       --ref-mhz 200 --mul 12 --div 8 --post-div 1 > adpll_ivlng_tb.spice

import argparse, re, sys


def module_ports(path, module):
    """Parse `module <module>( ... );` + input/output decls -> ordered [(name, dir, width)]."""
    src = open(path).read()
    m = re.search(r"\bmodule\s+" + re.escape(module) + r"\s*\((.*?)\)\s*;", src, re.S)
    if not m:
        sys.exit(f"module {module} not found in {path}")
    names = [p.strip() for p in m.group(1).split(",") if p.strip()]
    dirs, widths = {}, {}
    for d, rng, nm in re.findall(r"\b(input|output)\b\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)\s*;", src):
        dirs[nm] = d
        if rng:
            hi, lo = re.findall(r"-?\d+", rng)[:2]
            widths[nm] = (int(hi), int(lo))
        else:
            widths[nm] = None
    out = []
    for nm in names:
        if nm not in dirs:
            sys.exit(f"port {nm} of {module} has no input/output decl")
        out.append((nm, dirs[nm], widths[nm]))
    return out


def bits_msb_first(name, width):
    """Bracket slot names for a port, MSB-first (first slot = MSB). Scalars -> [name]."""
    if width is None:
        return [name]
    hi, lo = width
    return [f"{name}_{i}" for i in range(max(hi, lo), min(hi, lo) - 1, -1)]


def ring_tune_order(path, subckt):
    """tune_i bit indices in the ring .subckt port declaration order (e.g. [0,1,..,6])."""
    toks, grab = [], False
    for line in open(path):
        s = line.strip()
        if not grab and s.lower().startswith(f".subckt {subckt.lower()} "):
            toks += s.split()[2:]; grab = True
        elif grab and s.startswith("+"):
            toks += s[1:].split()
        elif grab:
            break
    order = []
    for t in toks:
        m = re.fullmatch(r"tune_i\[(\d+)\]", t)
        if m:
            order.append(int(m.group(1)))
    return order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--netlist", required=True)
    ap.add_argument("--module", default="adpll_bangbang_binary")
    ap.add_argument("--vvp", required=True, help="compiled Icarus vvp (loop + cell models)")
    ap.add_argument("--ring", default="ring.spice")
    ap.add_argument("--ring-subckt", default="ring_dco_binary")
    ap.add_argument("--corner", default="typical", help="sm141064.ngspice section (typical/ss/ff)")
    ap.add_argument("--ref-mhz", type=float, default=200.0)
    ap.add_argument("--mul", type=int, default=12)
    ap.add_argument("--div", type=int, default=8)
    ap.add_argument("--post-div", type=int, default=1)
    ap.add_argument("--vdd", type=float, default=3.3)
    ap.add_argument("--rst-ns", type=float, default=30.0)
    ap.add_argument("--en-ns", type=float, default=40.0)
    ap.add_argument("--tstop-ns", type=float, default=1000.0)
    ap.add_argument("--tstep-ps", type=float, default=20.0)
    a = ap.parse_args()

    ports = module_ports(a.netlist, a.module)
    ins = [(n, w) for (n, d, w) in ports if d == "input"]
    outs = [(n, w) for (n, d, w) in ports if d == "output"]

    consts = {"ref_mul_i": a.mul, "ref_div_i": a.div, "post_div_i": a.post_div}
    drive = {"clk_i": "clk_d", "rst_ni": "rst_d", "enable_i": "en_d", "dco_clk": "dco_d"}

    # Build the input bracket (MSB-first per bus), mapping each bit to a node name.
    in_nodes, tie_high, tie_low = [], [], []  # tie_* collect const bits for the report
    for name, w in ins:
        if name in drive:
            in_nodes.append(drive[name]); continue
        if name in consts:
            val, (hi, lo) = consts[name], w
            for i in range(max(hi, lo), min(hi, lo) - 1, -1):   # MSB-first
                bit = (val >> i) & 1
                in_nodes.append("d_one" if bit else "d_zero")
                (tie_high if bit else tie_low).append(f"{name}[{i}]")
            continue
        sys.exit(f"unhandled input port {name} (not a drive or const port)")

    # Output bracket (MSB-first). Name tune bits so the DCO can pick them up; others get a node too.
    out_nodes, tune_slots = [], {}   # tune_slots[i] = node carrying debug_dco_tune_o[i]
    for name, w in outs:
        slots = bits_msb_first(name if name != "debug_dco_tune_o" else "tune", w)
        if name == "debug_dco_tune_o":
            hi, lo = w
            for k, i in enumerate(range(max(hi, lo), min(hi, lo) - 1, -1)):
                tune_slots[i] = slots[k]
        out_nodes += slots

    tune_order = ring_tune_order(a.ring, a.ring_subckt)   # subckt tune_i declaration order
    if sorted(tune_order) != sorted(tune_slots):
        sys.exit(f"ring tune bits {tune_order} != netlist tune bits {sorted(tune_slots)}")
    # analog tune node per ring tune_i[i]
    tune_analog = {i: f"tia{i}" for i in tune_order}

    tper = 1000.0 / a.ref_mhz
    thi = tper / 2.0
    L = [
        f"* GATE-LEVEL ivlng cosim: ring DCO (ngspice) + {a.module} gate loop (Icarus/d_cosim)",
        f"* ref={a.ref_mhz}MHz  mul={a.mul} div={a.div} post_div={a.post_div}  "
        f"target F_DCO={a.mul/a.div*a.ref_mhz:.0f}MHz",
        # ngspice expands $PDK_ROOT in a .lib/.include FILE path (the corner is a literal section name,
        # which can't itself be a $VAR -- so it's baked in here from --corner).
        ".include $PDK_ROOT/gf180mcuD/libs.tech/ngspice/design.ngspice",
        f".lib $PDK_ROOT/gf180mcuD/libs.tech/ngspice/sm141064.ngspice {a.corner}",
        ".include " + a.ring,
        ".temp 25",
        f".param VDD={a.vdd}",
        "Vdd VDD 0 {VDD}",
        "Vss VSS 0 0",
        "",
        "* ---- digital loop (gate netlist, Icarus via ivlng) -- vector is decl-order, bus MSB-first ----",
        f'.model loopm d_cosim (simulation="ivlng" sim_args=["{a.vvp}"])',
        "a_loop [" + " ".join(in_nodes) + "]",
        "+      [" + " ".join(out_nodes) + "] loopm",
        "",
        "* ---- ring DCO (analog): VDD VSS clk_o enable_i tune_i[..] in .subckt order ----",
        "X_dco VDD VSS dco_clk en_a "
        + " ".join(tune_analog[i] for i in tune_order) + f" {a.ring_subckt}",
        "Cload dco_clk 0 2f",
        "",
        "* ---- sources: ref clock, reset (active-low), enable, and the const-1/const-0 rails ----",
        f"Vref refa 0 PULSE(0 {{VDD}} 0 0.1n 0.1n {thi-0.1:.3f}n {tper:.3f}n)",
        f"Vrst rsta 0 PWL(0 0 {a.rst_ns}n 0 {a.rst_ns+0.1:.3f}n {{VDD}})",
        f"Ven  en_a 0 PWL(0 0 {a.en_ns}n 0 {a.en_ns+0.1:.3f}n {{VDD}})",
        "Vone onea 0 {VDD}",
        "Vzero zeroa 0 0",
        "",
        "* ---- A/D + D/A bridges (ps delays so the adc tracks the ~hundreds-of-MHz DCO) ----",
        f".model adcm adc_bridge (in_low={a.vdd/3:.3f} in_high={2*a.vdd/3:.3f} rise_delay=10p fall_delay=10p)",
        f".model dacm dac_bridge (out_low=0 out_high={a.vdd:.3f} rise_delay=10p fall_delay=10p)",
        "a_adc [refa rsta en_a dco_clk onea zeroa] [clk_d rst_d en_d dco_d d_one d_zero] adcm",
        "a_dac_tune [" + " ".join(tune_slots[i] for i in sorted(tune_slots, reverse=True)) + "]",
        "+          [" + " ".join(tune_analog[i] for i in sorted(tune_slots, reverse=True)) + "] dacm",
        "a_dac_lock [lock_o] [lock_a] dacm",
        "",
        f".save lock_a dco_clk",
        f".tran {a.tstep_ps}p {a.tstop_ns}n uic",
        ".control",
        "run",
        f"meas tran t_lock when v(lock_a)={a.vdd/2:.3f} rise=1",
        ".endc",
        ".end",
        "",
    ]
    sys.stdout.write("\n".join(L))
    sys.stderr.write(f"# tied high: {tie_high}\n# tied low : {len(tie_low)} bits\n"
                     f"# ring tune order (subckt): {tune_order}\n")


if __name__ == "__main__":
    main()
