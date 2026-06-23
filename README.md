<!-- SPDX-License-Identifier: BSD-3-Clause -->
# adpll — all-digital ring-oscillator PLL

A reusable, all-standard-cell digital PLL IP: a programmable-ratio frequency synthesizer that
tunes a ring DCO so that

> **F_DCO = (mul / div) · F_clk_i**

where `mul` (feedback-multiply N) and `div` (reference divider M) are runtime inputs. The whole
control loop is plain synthesizable RTL; only the DCO rings and the TDC instantiate standard-cell
primitives (gf180 3.3 V today — see *Portability* below).

## Textbook references

The design is grounded in the two standard texts on digital/CMOS PLLs:

- **R. B. Staszewski & P. T. Balsara, *All-Digital Frequency Synthesizer in Deep-Submicron CMOS*,
  Wiley, 2006.** — the all-digital architecture: ring DCO with delay-element tuning (Ch. 2–3),
  thermometer / coarse–fine normalized DCO (Ch. 3, 5), the variable-phase / DCO-edge counter
  (Ch. 3), and the time-to-digital converter (Ch. 6).
- **B. Razavi, *Design of CMOS Phase-Locked Loops*, Cambridge.** — loop dynamics: type-II PI loop
  filter, damping / phase-margin, and the bang-bang limit cycle.

Per-block primary-paper citations (Kratyuk *TCAS-II* 2007 for the linear PI procedure, Hanumolu
*CICC* 2007 for the 1-bit sign detector, Da Dalt *TCAS-I* 2005 for gear shifting) are in the file
headers and in [`docs/adpll_survey.md`](docs/adpll_survey.md).

## What's here

- **Front end** — `adpll_freq_counter` (Gray-CDC DCO-edge counter over a runtime window) and
  `adpll_tdc` (sub-cycle phase, for the phase-domain loop); `adpll_lock_detect`.
- **Controllers** (`rtl/controller/`) — three frequency-locked loop filters: `bangbang`
  (1-bit sign), `linear` (multi-bit PI, power-of-two α/β), `gearshift` (adaptive-step binary
  search); plus `phase`, a true phase-locked type-II PI using the TDC.
- **DCOs** (`rtl/dco/`) — `binary`, `thermometer`, `muxtap`, `coarsefine` ring oscillators.
- **CSR** (`rtl/csr/`) — `s_axi_adpll_csr`, a single-PLL AXI4-Lite control/status block (enable/mul/div
  + lock/tune) showing how to drive one PLL over a bus.

Picking specific frozen controller×DCO configurations ("macros") and arraying many PLLs behind one
bus is integration left to the instantiating project (e.g. gf180mcu-peripherals builds a 12-PLL
array from these blocks) — this repo ships the reusable parameterizable parts.

## Layout

```
rtl/      adpll_freq_counter, adpll_lock_detect, adpll_tdc, controller/, dco/, csr/
sim/      self-contained Icarus testbenches (+ _sim_timescale.v)
scripts/  gen_ring_dco_spice.py (SPICE characterization), characterize_pll.py, plot_pll.py
docs/     adpll_survey.md (the variant survey, citations, results) + figures
```

## Verify (Icarus, no PDK)

```sh
make sim-adpll          # ring DCO oscillates + the loop locks
make sim-adpll-survey   # compare the FLL controllers (bang-bang / linear / gearshift)
make sim-adpll-matrix   # all 12 FLL variants (3 controllers x 4 DCOs)
make sim-adpll-phase    # phase-domain ADPLL (TDC): true phase lock
make sim-adpll-csr      # single-PLL CSR over AXI4-Lite
```

DCO frequency-vs-code is physical — characterize it in SPICE per PDK:

```sh
make dco-spice PDK_ROOT=/path/to/pdks PDK=gf180mcuD NGSPICE=/path/to/ngspice TOPOLOGY=binary
```

## Portability

Everything except the DCO rings and the TDC is PDK-agnostic. Those instantiate five gf180
primitives (`inv`/`nand2`/`mux2` in the rings; `dlybuff`/`dfxtp` in the TDC). To retarget,
re-implement those cells for your PDK and keep the ring's combinational loop out of optimization
(`keep`/`dont_touch`) and out of the clock-tree/STA (leave the DCO clock undefined in SDC). The
absolute frequency is set by the silicon, not RTL — the closed loop tunes to whatever ratio is
reachable, so there is no "delay" parameter to set.

## License

BSD-3-Clause (see file headers).
