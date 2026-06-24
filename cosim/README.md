# ADPLL gate-level mixed-signal cosim (ngspice + Icarus)

The analog ring DCO runs in ngspice (extracted transistors). The synthesized gf180 loop (detector →
filter → lock → post-divider) runs in Icarus. ngspice's XSPICE `d_cosim` closes the loop between them.
This is the chip's real analog/digital boundary. The ngspice side stays small — just the ring.

`make cosim ADPLL=<cfg> CORNER=<corner>` runs three steps. All artifacts land in git-ignored `build/`.

1. **Make `.spice` + `.v`.** LibreLane hardens the ring DCO and Magic extracts it → `ring.spice`
   (transistors + parasitics). yosys derives the loop from the `adpll_<filter>_<dco>` wrapper →
   `<cfg>_gl.v`. The ring is black-boxed. Its `clk_o` becomes a top input `dco_clk`. The rest maps to
   gf180 cells. Icarus compiles `<cfg>_gl.v` + the PDK cell models to a `vvp`.
2. **Make the testbench.** `generate_cosim_tb.py` emits `<cfg>_<corner>_cosim_tb.spice`. It `.include`s
   `ring.spice`. It instantiates the loop as a `d_cosim` device. It ties `ref_mul_i`/`ref_div_i`/
   `post_div_i` to rails (from `--mul/--div/--post-div`). It bridges the two domains with
   `adc_bridge`/`dac_bridge`: `dco_clk` ↔ ring `clk_o`, tune ↔ ring `tune_i`.
3. **Run.** ngspice runs the testbench. Its `d_cosim` model runs the `.v` (the `vvp`) through the
   `ivlng` shim. The digital loop steps in lockstep with the analog transient. `t_lock` is measured on
   `lock_o`.

`adpll_bangbang_binary @ typical` locks at **t ≈ 62 ns** and holds (200 MHz ref, mul/div 12/8 → 300 MHz).
A run takes ~5 min / 1000 ns. A config locks only if its mul/div is reachable by that DCO at that corner.

    nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical \
        PDK_ROOT=$PDK_ROOT IVL_PREFIX=/path/to/iverilog-libvvp
    # -> build/<cfg>_<corner>.log : "LOCKED (t_lock=...)" or "NO-LOCK"

## Details / gotchas

- **`iverilog`/`vvp` must be built `--enable-libvvp`.** `ivlng` `dlopen`s `libvvp` to run the `vvp`.
  Point `IVL_PREFIX` at it.
- The `d_cosim` port vector is module-declaration order. Every bus is **MSB-first** (verified vs ivlng).
- The loop `.v` needs a `` `timescale ``. Without one `vvp` runs at 1 s and nothing toggles. The Makefile
  adds one.
- **Append** ivlng's libs to `LD_LIBRARY_PATH`; never replace it. Replacing it breaks `digital.cm` →
  `d_cosim` becomes an "unknown device type". Never add `/usr/lib`; it breaks the nix glibc. The Makefile
  handles this.
- `adc_bridge` needs `rise/fall_delay=10p`. The default 1 ns can't track the ~hundreds-of-MHz DCO.
- ngspice expands `$PDK_ROOT` in the `.lib`/`.include` file paths. The corner is a literal section name.
