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

Per-block primary-paper citations (Kratyuk *TCAS-II* 2007 for the PI procedure, Hanumolu
*CICC* 2007 for the 1-bit sign detector, Da Dalt *TCAS-I* 2005 for gear shifting) are in the file
headers and in [`docs/adpll_survey.md`](docs/adpll_survey.md).

## What's here

A PLL is assembled from three swappable stages — **detector → loop filter → DCO** — plus a lock
detector. There is no monolithic "controller": the instantiating project wires the three blocks it
wants directly (see `sim/tb_adpll.v`).

- **Detectors** — `adpll_freq_detector` (frequency error: DCO-edge count over a runtime window vs a
  target) and `adpll_phase_detector` (phase error: reference/variable phase accumulators + the
  `adpll_tdc` sub-cycle fraction). Both build on the shared `adpll_freq_counter` (Gray-CDC edge
  counter); `adpll_lock_detector` watches the settled tune code.
- **Loop filters** (`rtl/loop_filter/`) — `bangbang` (1-bit sign), `proportionalintegral` (multi-bit PI,
  power-of-two α/β, anti-windup), `gearshift` (adaptive-step binary search). The error source is
  external, so the *same* `proportionalintegral` filter closes both the FLL (behind `adpll_freq_detector`)
  and the type-II phase loop (behind `adpll_phase_detector`) — only the widths/gains differ.
- **DCOs** (`rtl/dco/`) — `binary`, `thermometer`, `muxtap`, `coarsefine` ring oscillators.
- **Tech cells** (`rtl/tech_cells/`) — `adpll_cell_delay`/`_inv`/`_nand2`/`_mux2`, the only PDK-specific
  primitives. The rings and TDC instantiate these wrappers, not PDK cells, so retargeting a PDK
  means reimplementing just this dir (see *Portability*).
- **CSR** (`rtl/axi/`) — `s_axi_adpll_csr`, a single-PLL AXI4-Lite control/status block (enable/mul/div
  + lock/tune) showing how to drive one PLL over a bus.

Picking specific frozen detector×filter×DCO configurations and arraying many PLLs behind
one bus is integration left to the instantiating project (e.g. gf180mcu-peripherals builds a 12-PLL
array from these blocks) — this repo ships the reusable parameterizable parts.

## Layout

```
rtl/             adpll_freq_counter, adpll_freq_detector, adpll_phase_detector,
                 adpll_lock_detector, adpll_tdc
rtl/tech_cells   adpll_cell_delay / inv / nand2 / mux2 -- the PDK-specific primitives (THE retarget seam)
rtl/loop_filter  bangbang / pi / gearshift loop filters
rtl/dco          binary / thermometer / muxtap / coarsefine ring DCOs
rtl/axi          s_axi_adpll_csr (AXI4-Lite control/status)
sim/             self-contained Icarus testbenches + ring_dco_behavioral.sv (sim-only DCO model)
scripts/         characterize_pll.py, plot_pll.py (loop/DCO analysis + figures)
docs/            adpll_survey.md (the variant survey, citations, results) + figures
```

## Verify

```sh
make sim-adpll          # ring DCO oscillates + the loop locks
make sim-adpll-survey   # compare the FLL loop filters (bang-bang / proportional-integral / gearshift)
make sim-adpll-matrix   # all 12 FLL variants (3 loop filters x 4 DCOs)
make sim-adpll-phase    # phase-domain ADPLL (TDC): true phase lock
make sim-adpll-csr      # single-PLL CSR over AXI4-Lite
```

These run on **stock Icarus** (no PDK, no patched tools). The trick is the **DCO boundary**: the
real `rtl/dco/` rings are purely structural (built from `rtl/tech_cells/`), which is correct for
synthesis/SPICE but slow to simulate and not frequency-matched across variants. The digital sims
don't care how the ring is built, only that its frequency falls with `tune_i` — so the testbenches
compile `sim/ring_dco_behavioral.sv` (a fast `#`-delay clock with the same module/port/param
interface) instead of `rtl/dco/`, keeping the detector / loop filter / lock detector / CSR — the
actual digital logic — under test. The ring's real frequency-vs-code curve is physical and is
verified in **SPICE** — hardened as a macro (`librelane/ring_dco.yaml`), parasitic-extracted by
Magic, and swept through ngspice. Needs LibreLane + a gf180 PDK + ngspice ≥ 42 (the CI workflow
`.github/workflows/dco-spice.yml` runs it; locally, inside the toolchain env):

```sh
make dco-spice DCO=ring_dco_binary SWEEP=0,8,16,32,64,96,127   # freq-vs-code, e.g. code 0 ~= 337 MHz (TT)
```

The `ring_dco_*` modules carry `(* keep_hierarchy *)` so they survive as a swappable boundary in the
synthesized netlist: **post-synthesis gate-level sims** substitute the gate ring for
`sim/ring_dco_behavioral.sv` the same way, exercising the real synthesized control logic without
trying to simulate the ring. Synthesis (yosys + slang) elaborates the structural
`Target="gf180mcu_as_sc_mcu7t3v3"` cells directly — no patched-tool dependency.

## Portability

Every PDK-specific primitive is isolated in **`rtl/tech_cells/`** — the single retarget seam. The ring
DCOs and the TDC delay line instantiate only these wrappers (`adpll_cell_inv`/`_nand2`/`_mux2` in the
rings; `adpll_cell_delay` in the TDC, ports mirroring the gf180 cells), never a PDK cell directly.
Each wrapper picks its implementation from a `Target` **string parameter** (not a `` `define ``): the
DCOs pass `Target="gf180mcu_as_sc_mcu7t3v3"` (the gf180 3.3 V cell, `inv_2`/`nand2_2`/`mux2_2`/
`dlybuff_2`, with `keep`/`dont_touch`), and the default `"behavioral"` is an RTL `#`-delay model; an
unknown target is a `$fatal`. **To retarget a PDK (sky130, ASAP7, …), add a branch in `rtl/tech_cells/`
and pass its name as `Target`** — the rings, TDC, detectors, and loop filters are untouched. For
simulation the testbenches swap in a sim-only behavioural DCO model (`sim/ring_dco_behavioral.sv`)
rather than build the structural ring; the ring's real frequency-vs-code curve is physical and is
characterised in **SPICE**, not RTL. Keep the ring's combinational loop out of optimization
(`keep`/`dont_touch`) and out of the clock-tree/STA (leave the DCO clock undefined in SDC).

## License

BSD-3-Clause (see file headers).
