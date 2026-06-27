#!/usr/bin/env python3
# Annotate a VCD with instantaneous clock frequencies.
#
# Given a VCD that contains a DCO clock and a reference clock (1-bit signals), inject two real-valued
# traces -- dco_freq_mhz and ref_freq_mhz -- each computed at every rising edge as 1/(t - t_prev),
# i.e. the inverse of the spacing between consecutive posedges. Works on both the behavioural sim VCD
# (dco_clk / clk) and the gate-level cosim VCD (dco_d / clk_d from ngspice eprvcd), so the loop's
# frequency acquisition + the +-1 LSB stutter are visible as analog traces in GTKWave / Surfer.
#
#   ./vcd_add_freq.py in.vcd out.vcd --dco dco_clk --ref clk
#   ./vcd_add_freq.py cosim.vcd cosim_freq.vcd --dco dco_d --ref clk_d

import argparse, re, sys

UNIT_S = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}


def parse_timescale(text):
    m = re.search(r"\$timescale\s+([0-9.]+)\s*([munpf]?s)\s*\$end", text)
    if not m:
        sys.exit("could not find $timescale in VCD")
    return float(m.group(1)) * UNIT_S[m.group(2)]


def find_id(header, name):
    # $var <type> <width> <id> <name> [bitrange] $end ; match a 1-bit signal by exact name
    for m in re.finditer(r"\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+?)(?:\s+\[[^\]]*\])?\s+\$end", header):
        width, ident, vname = m.group(1), m.group(2), m.group(3)
        if vname == name:
            return ident, int(width)
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp"); ap.add_argument("out")
    ap.add_argument("--dco", default="dco_clk", help="DCO clock signal name")
    ap.add_argument("--ref", default="clk", help="reference clock signal name")
    a = ap.parse_args()

    text = open(a.inp).read()
    head, _, body = text.partition("$enddefinitions")
    body = body.partition("$end")[2]  # drop the "$end" that closes $enddefinitions

    ts_s = parse_timescale(head)
    dco_id, _ = find_id(head, a.dco)
    ref_id, _ = find_id(head, a.ref)
    if not dco_id or not ref_id:
        sys.exit(f"signal not found: dco={a.dco}->{dco_id}  ref={a.ref}->{ref_id}")

    # fresh identifier codes that aren't already used
    used = set(re.findall(r"\$var\s+\S+\s+\d+\s+(\S+)\s", head))
    def fresh(seed):
        i = 0
        while True:
            cand = f"{seed}{i}"
            if cand not in used:
                used.add(cand); return cand
            i += 1
    fq_dco, fq_ref = fresh("fD"), fresh("fR")

    # rewrite header: add the two real vars right before $enddefinitions
    inject = (f"$var real 64 {fq_dco} dco_freq_mhz $end\n"
              f"$var real 64 {fq_ref} ref_freq_mhz $end\n")
    out = [head, inject, "$enddefinitions $end\n"]

    # stream the body; at each clock posedge emit the instantaneous frequency
    last = {dco_id: None, ref_id: None}     # last posedge time (in ticks)
    prev = {dco_id: "x", ref_id: "x"}       # last seen scalar value
    fq_of = {dco_id: fq_dco, ref_id: fq_ref}
    t = 0
    mhz = lambda dt: 1e-6 / (dt * ts_s) if dt > 0 else 0.0

    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if s[0] == "#":
            t = int(s[1:]); out.append(s + "\n"); continue
        out.append(s + "\n")
        # scalar value change: <value><id>  (value in 01xz)
        if s[0] in "01xzXZ" and len(s) >= 2:
            val, ident = s[0], s[1:]
            if ident in last:
                if val == "1" and prev[ident] != "1":      # rising edge
                    if last[ident] is not None:
                        out.append(f"r{mhz(t - last[ident]):.4f} {fq_of[ident]}\n")
                    last[ident] = t
                prev[ident] = val

    open(a.out, "w").write("".join(out))
    print(f"wrote {a.out}: +dco_freq_mhz({a.dco}) +ref_freq_mhz({a.ref}), timescale={ts_s:g}s")


if __name__ == "__main__":
    main()
