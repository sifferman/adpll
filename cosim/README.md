# ADPLL mixed-signal co-simulation (ngspice + Verilator)

**Proof of concept.** Simulate only the **analog ring DCO** in ngspice (extracted transistor netlist,
real physics) and the **digital loop** (freq detector → bang-bang filter → lock detector) in Verilog,
coupled into a true closed loop through ngspice's `d_cosim` XSPICE code model. This matches the chip's
real analog/digital boundary (DCO = analog macro, rest = synthesized digital) and keeps the ngspice
matrix tiny (the ring is ~404 devices vs ~1450 for the whole PLL).

## Result

The closed loop **locks**: with the extracted `ring_dco_binary` and a 200 MHz reference, mul/div = 12/8
(→ 300 MHz target), `lock_o` asserts at **t ≈ 600 ns** (tune settles at code ≈ 3–4), in **~5.8 min**
wall-clock for a 1000 ns run. Compare the full-transistor closed loop (whole PLL in ngspice):
~14 min for 600 ns. Cosim is ~3–4× faster *and* is a true loop with the real ring transient — and it
scales: the analog cost is fixed at the ring regardless of how much digital logic the loop grows.

## Files

- `adpll_loop_cosim.sv` — the digital loop top (detector + filter + lock), `dco_clk_i` as an input,
  `tune_o`/`lock_o` as outputs. mul/div baked for the POC. DCO is **not** here.
- `build_cosim_so.sh` + `gen_headers.py` — build the `d_cosim` shared library from Verilog.
- `adpll_cosim.cir` — the ngspice deck: ring DCO + `d_cosim` loop + `adc_bridge`/`dac_bridge`.

## Run

    cd third_party/adpll/cosim
    make -C .. dco-spice DCO=ring_dco_binary          # produces the extracted ring netlist
    cp ../librelane/runs/*/final/spice/ring_dco_binary.spice .
    nix develop ../../.. -c ./build_cosim_so.sh adpll_loop \
        adpll_loop_cosim.sv ../rtl/adpll_freq_detector.sv ../rtl/adpll_freq_counter.sv \
        ../rtl/loop_filter/adpll_loop_filter_bangbang.sv ../rtl/adpll_lock_detector.sv
    # edit adpll_cosim.cir's PDK ngspice path, then:
    nix develop ../../.. -c env -u DISPLAY \
        LD_LIBRARY_PATH=$(ls -d /nix/store/*gcc-14*-lib/lib | head -1) ngspice -b adpll_cosim.cir

## Gotchas (each one cost a debugging cycle — read before editing)

1. **Build the `.so` manually.** ngspice's `vlnggen` script wants an X display, `~/tmp`, and an
   interactive interpreter — it fails headless. `build_cosim_so.sh` does the same steps directly and
   links the shim objects **without** `verilator_main.o` (we want the lib, not an exe).
2. **`~/tmp` must exist** — ngspice's temp dir; create it once.
3. **`simulation="..."` must contain a slash** (`./adpll_loop.so` or absolute). `dlopen` does not
   search the cwd, so a bare name fails with "failed to load simulation binary".
4. **Run with `LD_LIBRARY_PATH` → the nix `libstdc++`** ngspice itself uses, and `env -u DISPLAY`.
5. **The `d_cosim` port-vector order is the order in `<obj_dir>/inputs.h` / `outputs.h`, which is how
   Verilator emits the ports — NOT the Verilog source order.** Verilator reordered our inputs to
   `clk_i, rst_ni, dco_clk_i, enable_i`. Wiring the `a_loop [...]` vector in source order silently
   swapped `enable_i` and `dco_clk_i` → the loop never enabled and counted ~0 edges. **Always read
   `inputs.h`/`outputs.h` and order the `a` vector to match.** Output **buses are MSB-first** in the
   vector (`for (i = msb; i >= lsb; --i)` in the shim), so `tune_o[6:0]` maps to vector nodes
   `[t6 … t0]` — reverse them into the DCO.
6. **`adc_bridge` needs picosecond `rise_delay`/`fall_delay`.** The default 1 ns can't track the
   ~336 MHz DCO (it delivered ~108 MHz of edges); the freq counter then undercounts. Use `10p`.
7. **Build `--timing`** (`-DWITH_TIMING` shim path). The multi-clock loop (ref + DCO) advances its
   FFs through the timing scheduler; `verilated_timing.o` is folded into `verilated.o` in v5.046.

## Status / next steps

POC only. The lock is intermittent (tune dithers a bit wider than the ±1 lock band for this coarse
mul/div) — tighten the filter/band or pick a finer ratio for a clean steady lock. To productionize:
generate the loop top from the real `adpll_<filter>_<dco>` wrappers (DCO removed), parameterize the
PDK path, and wrap the run in a make target / CI job as the rigorous closed-loop sign-off (the fast
per-config matrix stays the open-loop DCO sweep + the digital lock sims).
