#!/usr/bin/env python3
# Closed-loop ngspice transient of a hardened full adpll, swept over several target frequencies,
# each run until it locks.
#
# Input is the Magic-extracted SPICE netlist from the LibreLane harden of one adpll_<filter>_<dco>
# (runs/*/final/spice/<design>.spice) -- the WHOLE PLL at transistor level with layout parasitics:
# freq detector, loop filter, lock detector, and the ring DCO, straight from the .sv via the real
# flow. For each requested target frequency we drive the reference clock, release reset, tie
# mul_i/div_i to the ratio, raise enable, and run a transient until lock_o asserts -- measuring the
# textbook closed-loop metrics:
#   * time-to-lock  : when lock_o first rises (from enable)
#   * locked F_DCO  : DCO period measured near the end of the run
# The loop is shrunk at harden time (-G DcoNumTuneBits=4 ...) so lock happens in ~tens of windows,
# which a transistor-level transient can reach. Target: F_DCO = (mul/div)*F_ref, mul = round(target*div/ref).
#
#   ./adpll_lock.py --extracted runs/*/final/spice/adpll_bangbang_binary.spice \
#       --pdk-ngspice <pdk>/libs.tech/ngspice --design adpll_bangbang_binary \
#       --ref-mhz 200 --div 8 --targets-mhz 220,260,300,340

import argparse, os, re, subprocess, sys


def subckt_ports(path, design):
    """Return the ordered port list of `.subckt <design> ...` (handles + continuations)."""
    toks, grabbing = [], False
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not grabbing and s.lower().startswith(f".subckt {design.lower()} "):
                toks += s.split()[2:]; grabbing = True
            elif grabbing and s.startswith("+"):
                toks += s[1:].split()
            elif grabbing:
                break
    return toks


def bit_index(port, base):
    m = re.fullmatch(re.escape(base) + r"\[(\d+)\]", port)
    return int(m.group(1)) if m else None


def deck(a, ports, vth, mul, div):
    tper_ns = 1000.0 / a.ref_mhz
    thi_ns = tper_ns / 2.0
    sane = lambda p: "V" + re.sub(r"[^A-Za-z0-9]", "_", p)
    L = [f"* {a.design} closed-loop lock  ref={a.ref_mhz}MHz mul={mul} div={div} corner={a.corner}",
         f".include {os.path.join(a.pdk_ngspice, 'design.ngspice')}",
         f".lib {os.path.join(a.pdk_ngspice, 'sm141064.ngspice')} {a.corner}",
         f".include {os.path.abspath(a.extracted)}",
         f".temp {a.temp}",
         f".param VDD={a.vdd}",
         "Vdd VDD 0 {VDD}",
         "Vss VSS 0 0",
         f"Vclk clk_i 0 PULSE(0 {{VDD}} 0 0.1n 0.1n {thi_ns-0.1:.3f}n {tper_ns:.3f}n)",
         f"Vrst rst_ni 0 PWL(0 0 {a.rst_ns}n 0 {a.rst_ns+0.1:.3f}n {{VDD}})",
         f"Ven enable_i 0 PWL(0 0 {a.en_ns}n 0 {a.en_ns+0.1:.3f}n {{VDD}})"]
    for p in ports:
        k = bit_index(p, "ref_mul_i")
        if k is not None:
            L.append(f"{sane(p)} {p} 0 " + ("{VDD}" if (mul >> k) & 1 else "0"))
        k = bit_index(p, "ref_div_i")
        if k is not None:
            L.append(f"{sane(p)} {p} 0 " + ("{VDD}" if (div >> k) & 1 else "0"))
        k = bit_index(p, "post_div_i")           # tie to 1 = passthrough (loop locks on the raw DCO)
        if k is not None:
            L.append(f"{sane(p)} {p} 0 " + ("{VDD}" if k == 0 else "0"))
    L.append("Cdco debug_dco_clk_o 0 2f")
    L.append("Cout clk_o 0 2f")
    L.append("Clk lock_o 0 2f")
    L.append("X1 " + " ".join(ports) + f" {a.design}")
    td = max(a.tstop_ns - 30.0, a.tstop_ns * 0.9)
    L += [f".tran {a.tstep_ps}p {a.tstop_ns}n uic",
          ".control", "run",
          f"meas tran t_lock WHEN v(lock_o)={vth:.4f} RISE=1",
          f"meas tran t_a WHEN v(debug_dco_clk_o)={vth:.4f} RISE=1 TD={td:.3f}n",
          f"meas tran t_b WHEN v(debug_dco_clk_o)={vth:.4f} RISE=2 TD={td:.3f}n",
          ".endc", ".end", ""]
    return "\n".join(L)


def run_one(a, ports, vth, mul, div):
    text = deck(a, ports, vth, mul, div)
    path = os.path.join(a.workdir, f"adpll_lock_{a.design}_{a.corner}_m{mul}d{div}.spice")
    open(path, "w").write(text)
    r = subprocess.run([a.ngspice, "-b", path], capture_output=True, text=True, timeout=a.timeout_s)
    out = r.stdout + "\n" + r.stderr
    grab = lambda n: (lambda m: float(m[-1]) if m else None)(re.findall(rf"{n}\s*=\s*([0-9.eE+\-]+)", out))
    t_lock, t_a, t_b = grab("t_lock"), grab("t_a"), grab("t_b")
    flock = (1.0 / (t_b - t_a)) if (t_a is not None and t_b is not None and t_b > t_a) else None
    return t_lock, flock, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extracted", required=True)
    ap.add_argument("--pdk-ngspice", required=True)
    ap.add_argument("--design", default="adpll_bangbang_binary")
    ap.add_argument("--ngspice", default="ngspice")
    ap.add_argument("--ref-mhz", type=float, default=200.0)
    ap.add_argument("--ratios", default="8/8,10/8,12/8,14/8",
                    help="comma list of mul/div synthesizer ratios (F_DCO = mul/div * ref) to lock at")
    ap.add_argument("--corner", default="typical")
    ap.add_argument("--vdd", type=float, default=3.3)
    ap.add_argument("--temp", type=float, default=25.0)
    ap.add_argument("--rst-ns", type=float, default=30.0)
    ap.add_argument("--en-ns", type=float, default=40.0)
    ap.add_argument("--tstop-ns", type=float, default=1200.0)
    ap.add_argument("--tstep-ps", type=float, default=20.0)
    ap.add_argument("--timeout-s", type=int, default=14400)
    ap.add_argument("--workdir", default="/tmp")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    model = os.path.join(a.pdk_ngspice, "design.ngspice")
    if not os.path.isfile(model):
        sys.exit(f"PDK ngspice models not found: '{model}' (--pdk-ngspice='{a.pdk_ngspice}').")
    ports = subckt_ports(a.extracted, a.design)
    if not ports:
        sys.exit(f"could not find .subckt {a.design} in {a.extracted}")
    for need in ("clk_i", "rst_ni", "enable_i", "lock_o", "debug_dco_clk_o"):
        if need not in ports:
            sys.exit(f"expected port '{need}' not in .subckt {a.design}: {' '.join(ports)}")

    vth = a.vdd / 2.0
    pairs = []
    for item in a.ratios.split(","):
        mul, div = item.split("/")
        pairs.append((int(mul), int(div)))
    rows = [f"# {a.design}  closed-loop lock  corner={a.corner} vdd={a.vdd} temp={a.temp}",
            f"# ref = {a.ref_mhz:.0f} MHz   (target F_DCO = mul/div * ref;  window = div * T_ref)",
            f"# {'mul':>4} {'div':>4}  {'target_MHz':>10}  {'lock_ns':>9}  {'F_DCO_MHz':>10}  result"]
    n_lock, last_fail = 0, None
    for mul, div in pairs:
        tgt = mul / div * a.ref_mhz
        t_lock, flock, out = run_one(a, ports, vth, mul, div)
        if t_lock is None:
            rows.append(f"  {mul:>4} {div:>4}  {tgt:>10.1f}  {'--':>9}  {'--':>10}  NO-LOCK")
            last_fail = (mul, div, out)
        else:
            n_lock += 1
            lock_ns = (t_lock - a.en_ns * 1e-9) * 1e9
            fmhz = f"{flock/1e6:.1f}" if flock else "?"
            rows.append(f"  {mul:>4} {div:>4}  {tgt:>10.1f}  {lock_ns:>9.1f}  {fmhz:>10}  LOCKED")

    table = "\n".join(rows) + "\n"
    sys.stdout.write(table)
    if a.out:
        open(a.out, "w").write(table)

    if n_lock == 0:
        mul, div, out = last_fail
        sys.stderr.write(
            f"\nERROR: {a.design} never locked at any of {len(pairs)} ratios (e.g. mul={mul} div={div}, "
            f"ref={a.ref_mhz}MHz -> {mul/div*a.ref_mhz:.0f} MHz). Unreachable tune range or no convergence. "
            f"ngspice tail:\n---- ngspice ----\n" + "\n".join(out.splitlines()[-40:]) + "\n---- end ----\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
