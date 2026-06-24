# ADPLL gate-level mixed-signal cosim (ngspice + Icarus)

The analog ring DCO runs in ngspice (extracted transistors); the synthesized gf180 loop (detector →
filter → lock → post-divider) runs in Icarus, closed into a loop through ngspice's XSPICE `d_cosim`.
This is the chip's real analog/digital boundary, and keeps the ngspice side to just the ring.

`make cosim ADPLL=<cfg> CORNER=<corner>` runs three steps (all artifacts under git-ignored `build/`):

1. **Generate `.spice` + `.v`.** LibreLane hardens the ring DCO and Magic-extracts it →
   `ring.spice` (transistor netlist with parasitics). yosys derives the loop from the
   `adpll_<filter>_<dco>` wrapper → `<cfg>_gl.v`: the ring is black-boxed, its `clk_o` is
   `expose -input`'d as a top `dco_clk`, the rest is mapped to gf180 cells. `<cfg>_gl.v` + the PDK's
   behavioural cell models compile (Icarus) to a `vvp`.
2. **Generate the testbench.** `generate_cosim_tb.py` emits `<cfg>_<corner>_cosim_tb.spice`: it
   `.include`s `ring.spice`, instantiates the loop as a `d_cosim` device, ties `ref_mul_i`/`ref_div_i`/
   `post_div_i` to rails (from `--mul/--div/--post-div`), and bridges the two domains (`adc_bridge`/
   `dac_bridge`) — `dco_clk` ↔ ring `clk_o`, tune ↔ ring `tune_i`.
3. **Run.** ngspice executes the testbench; its `d_cosim` XSPICE model runs the `.v` (the `vvp`) via the
   `ivlng` shim, stepping the digital loop in lockstep with the analog transient. `lock_o` → `lock_a` is
   measured for `t_lock`.

`adpll_bangbang_binary @ typical` (200 MHz ref, mul/div 12/8 → 300 MHz) locks at **t ≈ 62 ns** and holds,
~5 min / 1000 ns. A config locks only if mul/div is reachable by that DCO at that corner.

    nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical \
        PDK_ROOT=$PDK_ROOT IVL_PREFIX=/path/to/iverilog-libvvp
    # -> build/<cfg>_<corner>.log : "LOCKED (t_lock=...)" or "NO-LOCK"

## Details / gotchas

- **`iverilog`/`vvp` must be built `--enable-libvvp`** — `ivlng` `dlopen`s `libvvp` to run the `vvp`.
  Point `IVL_PREFIX` at that install.
- The `d_cosim` port vector is module-declaration order, every bus **MSB-first** (verified vs ivlng).
- The loop `.v` needs a `` `timescale `` or `vvp` runs at 1 s and nothing toggles (Makefile adds one).
- **Append** ivlng's libs to `LD_LIBRARY_PATH`, never replace it (replacing breaks `digital.cm` →
  `d_cosim` "unknown device type"); never add `/usr/lib` (breaks the nix glibc). The Makefile handles it.
- `adc_bridge` needs `rise/fall_delay=10p` to track the ~hundreds-of-MHz DCO (default 1 ns can't).
- `$PDK_ROOT` is expanded by ngspice in the `.lib`/`.include` file paths; the corner is a literal section.
