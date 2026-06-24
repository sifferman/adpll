#!/usr/bin/env python3
# Sweep a hardened ring_dco's tune code through ngspice and report frequency-vs-code.
#
# Input is the Magic-extracted SPICE netlist from the LibreLane harden
# (runs/*/final/spice/<design>.spice) -- transistor-level with layout parasitics, the single
# source of truth straight from the .sv via the real flow. For each tune code we tie the tune_i
# bits to the rails, kick `enable_i` to start the ring, run a transient, and measure the
# oscillation period from two rising crossings.
#
#   ./dco_freq.py --extracted runs/*/final/spice/ring_dco_binary.spice \
#       --pdk-ngspice <pdk>/libs.tech/ngspice --ngspice ngspice \
#       --bits 7 --sweep 0,8,16,32,64,127

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


def deck(extracted, ngspice_dir, design, ports, code, bits, corner, vdd, temp,
         tstop_ns, tstep_ps, settle, periods):
    vth = vdd / 2.0
    L = [f"* {design} freq  code={code} corner={corner} vdd={vdd} temp={temp}",
         f".include {os.path.join(ngspice_dir, 'design.ngspice')}",
         f".lib {os.path.join(ngspice_dir, 'sm141064.ngspice')} {corner}",
         f".include {os.path.abspath(extracted)}",
         f".temp {temp}",
         f".param VDD={vdd}",
         "Vdd VDD 0 {VDD}",
         "Vss VSS 0 0",
         "Ven enable_i 0 PWL(0 0 1n 0 1.05n {VDD})"]
    for i in range(bits):
        L.append(f"Vt{i} tune_i[{i}] 0 {{VDD}}" if (code >> i) & 1 else f"Vt{i} tune_i[{i}] 0 0")
    L.append("Cload clk_o 0 1f")
    # instantiate the extracted ring in its declared port order; tune_i[k] tied above
    inst = " ".join(p if not p.startswith("tune_i") else p for p in ports)
    L.append(f"X1 {inst} {design}")
    L += [f".tran {tstep_ps}p {tstop_ns}n uic",
          ".control", "run",
          f"meas tran t_a WHEN v(clk_o)={vth:.4f} RISE={settle}",
          f"meas tran t_b WHEN v(clk_o)={vth:.4f} RISE={settle + periods}",
          ".endc", ".end", ""]
    return "\n".join(L)


def run_one(text, workdir, tag, ngspice, periods):
    p = os.path.join(workdir, f"dco_{tag}.spice")
    open(p, "w").write(text)
    r = subprocess.run([ngspice, "-b", p], capture_output=True, text=True, timeout=1800)
    out = r.stdout + "\n" + r.stderr
    ta = re.findall(r"t_a\s*=\s*([0-9.eE+\-]+)", out)
    tb = re.findall(r"t_b\s*=\s*([0-9.eE+\-]+)", out)
    if ta and tb:
        per = (float(tb[-1]) - float(ta[-1])) / periods
        if per > 0:
            return 1.0 / per, per, out
    return None, None, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extracted", required=True, help="Magic-extracted <design>.spice")
    ap.add_argument("--pdk-ngspice", required=True, help="<pdk>/libs.tech/ngspice dir")
    ap.add_argument("--design", default="ring_dco_binary")
    ap.add_argument("--ngspice", default="ngspice")
    ap.add_argument("--bits", type=int, default=7)
    ap.add_argument("--sweep", default="0,8,16,32,64,127")
    ap.add_argument("--corner", default="typical")
    ap.add_argument("--vdd", type=float, default=3.3)
    ap.add_argument("--temp", type=float, default=25.0)
    ap.add_argument("--tstop-ns", type=float, default=200.0)   # ~50+ periods at 200-400 MHz
    ap.add_argument("--tstep-ps", type=float, default=10.0)
    ap.add_argument("--settle", type=int, default=8)
    ap.add_argument("--periods", type=int, default=10)
    ap.add_argument("--workdir", default="/tmp")
    ap.add_argument("--out", default=None, help="also write the freq-vs-code table to this file")
    a = ap.parse_args()

    # Fail early with a clear message if the PDK SPICE models aren't where we were told -- otherwise
    # every code silently fails to oscillate (transistors with no model) and the cause is opaque.
    model = os.path.join(a.pdk_ngspice, "design.ngspice")
    if not os.path.isfile(model):
        sys.exit(f"PDK ngspice models not found: '{model}' does not exist "
                 f"(--pdk-ngspice='{a.pdk_ngspice}'). Check PDK_NGSPICE resolution.")

    ports = subckt_ports(a.extracted, a.design)
    if not ports:
        sys.exit(f"could not find .subckt {a.design} in {a.extracted}")
    codes = [int(c) for c in a.sweep.split(",")]

    rows = [f"# {a.design}  corner={a.corner} vdd={a.vdd} temp={a.temp}  (ports: {' '.join(ports)})",
            f"# {'code':>5}  {'freq_MHz':>10}  {'period_ns':>10}"]
    data = []          # (code, freq_Hz) for codes that oscillated
    first_fail = None  # (code, ngspice output) of the first NO-OSC, for diagnostics
    for c in codes:
        text = deck(a.extracted, a.pdk_ngspice, a.design, ports, c, a.bits,
                    a.corner, a.vdd, a.temp, a.tstop_ns, a.tstep_ps, a.settle, a.periods)
        f, per, out = run_one(text, a.workdir, f"{a.design}_{a.corner}_{c}", a.ngspice, a.periods)
        if f is None:
            rows.append(f"  {c:>5}  {'NO-OSC':>10}")
            if first_fail is None:
                first_fail = (c, out)
        else:
            rows.append(f"  {c:>5}  {f/1e6:>10.1f}  {per*1e9:>10.4f}")
            data.append((c, f))

    # Textbook DCO-characterisation stats from the freq-vs-code curve (Staszewski Ch.3/5): tuning
    # range, average gain K_DCO, and monotonicity (the curve should fall with tune; a rise flags the
    # long-ring multi-mode region). Time-to-lock is a closed-loop metric (separate flow), not here.
    rows.append("#")
    if len(data) >= 2:
        data.sort()
        (c_lo, _), (c_hi, _) = data[0], data[-1]
        fmaxc, fmax = max(data, key=lambda p: p[1])
        fminc, fmin = min(data, key=lambda p: p[1])
        gain = (data[-1][1] - data[0][1]) / (data[-1][0] - data[0][0]) / 1e6  # MHz per code (signed)
        mono = all(data[i + 1][1] <= data[i][1] for i in range(len(data) - 1))
        rows += [
            f"# stats ({len(data)}/{len(codes)} codes oscillated):",
            f"#   f_max      = {fmax/1e6:8.1f} MHz  @ code {fmaxc}",
            f"#   f_min      = {fmin/1e6:8.1f} MHz  @ code {fminc}",
            f"#   tuning     = {fmax/fmin:6.2f}x  ({(fmax-fmin)/1e6:.1f} MHz span)",
            f"#   avg K_DCO  = {gain:8.2f} MHz/code  (over codes {c_lo}..{c_hi})",
            f"#   monotonic  = {'yes (f falls with tune)' if mono else 'NO -- multi-mode region present'}",
        ]
    else:
        rows.append(f"# stats: only {len(data)} code(s) oscillated -- not enough to characterise")

    table = "\n".join(rows) + "\n"
    sys.stdout.write(table)                              # full log stream (CI step)
    if a.out:                                            # just the table (small, for the summary)
        open(a.out, "w").write(table)

    # A sweep where NOTHING oscillated is a flow failure, not a result -- almost always the model
    # include didn't resolve (PDK_NGSPICE wrong) or the subckt didn't elaborate, NOT a dead ring.
    # Surface ngspice's own output for the first failing code and exit non-zero so CI goes red
    # instead of silently reporting a table of NO-OSC.
    if not data:
        c, out = first_fail if first_fail else (codes[0], "(no ngspice output captured)")
        sys.stderr.write(
            f"\nERROR: no tune code oscillated ({len(codes)} tried). This is a flow failure, not a\n"
            f"dead DCO -- check that the transistor models were included (PDK_NGSPICE='{a.pdk_ngspice}')\n"
            f"and that .subckt {a.design} elaborated. ngspice output for code {c}:\n"
            "---- ngspice ----\n" + (out or "") + "\n---- end ----\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
