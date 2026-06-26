#!/usr/bin/env python3
# Convert a dco_freq.py freq-vs-code sweep (the real extracted-ring SPICE characterization) into a
# 128-entry half-period lookup table (hex picoseconds) for the behavioural DCO's table mode. This is
# what makes the behavioural sim behave like the cosim: instead of the smooth illustrative curve
# (1.0+0.1*tune ns), the behavioural ring replays the ring's ACTUAL freq-vs-code -- including the
# binary ring's multi-mode non-monotonicity and the muxtap ring's steep region + NO-OSC dead zone.
#
# A code that did not oscillate in SPICE ("NO-OSC") maps to 0 = the sentinel the behavioural model
# treats as "ring stalled" (clk held). Codes between the swept points are linearly interpolated
# (period), so an every-2-codes sweep fills all 128.
#
#   ./dco_table_from_sweep.py --in full_muxtap.txt --bits 7 --out dco_table_muxtap.mem

import argparse, re


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True, help="dco_freq.py output .txt")
    ap.add_argument("--bits", type=int, default=7)
    ap.add_argument("--out", required=True, help="output .mem (hex half-period ps, one per code)")
    a = ap.parse_args()

    n = 1 << a.bits
    period_ns = {}              # code -> period_ns (None = NO-OSC)
    for line in open(a.inp):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        f = s.split()
        code = int(f[0])
        if "NO-OSC" in s:
            period_ns[code] = None
        else:
            period_ns[code] = float(f[2])     # column: code freq_MHz period_ns

    swept = sorted(period_ns)
    half_ps = [0] * n           # 0 = NO-OSC / stalled
    for code in range(n):
        if code in period_ns:
            p = period_ns[code]
        else:
            # linear-interpolate period between the nearest swept codes (NO-OSC if either side is)
            lo = max((c for c in swept if c <= code), default=None)
            hi = min((c for c in swept if c >= code), default=None)
            if lo is None or hi is None:
                p = None
            elif period_ns[lo] is None or period_ns[hi] is None:
                p = None
            elif lo == hi:
                p = period_ns[lo]
            else:
                t = (code - lo) / (hi - lo)
                p = period_ns[lo] + t * (period_ns[hi] - period_ns[lo])
        half_ps[code] = 0 if p is None else max(1, round(p * 1000.0 / 2.0))

    with open(a.out, "w") as out:
        for code in range(n):
            out.write(f"{half_ps[code]:x}\n")
    osc = sum(1 for v in half_ps if v)
    print(f"{a.out}: {osc}/{n} codes oscillate; "
          f"f_max={1e6/(2*min(v for v in half_ps if v)):.0f}MHz f_min={1e6/(2*max(v for v in half_ps if v)):.0f}MHz")


if __name__ == "__main__":
    main()
