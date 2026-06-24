# ADPLL gate-level mixed-signal cosim (ngspice + Icarus)

The ring DCO runs in ngspice (extracted transistors); the synthesized gf180 loop (detector → filter →
lock → post-divider) runs in Icarus, coupled into a closed loop via ngspice's `d_cosim` + the `ivlng`
shim. This is the chip's real analog/digital boundary, and keeps the ngspice side small (just the ring).

The loop is the **real gate netlist**, derived from the wrapper by `make` (no hand-written top): yosys
black-boxes the ring, `expose -input`s its `clk_o` as a top `dco_clk`, keeps `debug_dco_tune_o`, maps to
gf180 cells, and `write_verilog`s it; that plus the PDK cell models compiles to a `vvp`.

## Run

    # one config at one corner, in the nix devshell with an enabled gf180 PDK:
    nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical \
        PDK_ROOT=$PDK_ROOT IVL_PREFIX=/path/to/iverilog-libvvp
    # -> build/<cfg>_<corner>.log : "LOCKED (t_lock=...)" or "NO-LOCK"

`adpll_bangbang_binary @ typical` locks at **t ≈ 62 ns** and holds, ~5 min / 1000 ns. The other 11
configs and ss/ff corners use the same target; a config locks only if mul/div is reachable by that DCO.

**Requires `iverilog`/`vvp` built with `--enable-libvvp`** (ivlng `dlopen`s `libvvp`); point `IVL_PREFIX`
at it. `Makefile` is the source of truth — each step is a file target under `build/` (git-ignored).

## Gotchas

- `d_cosim` port vector is module-declaration order, every bus **MSB-first** (verified vs ivlng).
- Loop `.v` needs a `` `timescale `` or `vvp` runs at 1 s and nothing toggles (Makefile adds one).
- **Append** ivlng's libs to `LD_LIBRARY_PATH`, never replace it (replacing breaks `digital.cm` → `d_cosim`
  "unknown device type"); never add `/usr/lib` (breaks the nix glibc). The Makefile handles this.
- `adc_bridge` needs `rise/fall_delay=10p` to track the ~hundreds-of-MHz DCO (default 1 ns can't).
