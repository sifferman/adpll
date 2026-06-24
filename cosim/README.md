# ADPLL gate-level mixed-signal cosim (ngspice + Icarus)

This is a gate-level mixed-signal cosim (ngspice + Icarus).
The analog ring DCO runs in ngspice (extracted transistors), and everything else runs in Icarus.
We use ngspice's XSPICE `d_cosim` feature.

```bash
nix develop ../.. -c \
  make -C cosim cosim \
    ADPLL=adpll_bangbang_binary \
    CORNER=typical \
    PDK_ROOT=$PDK_ROOT \
    IVL_PREFIX=/path/to/iverilog-libvvp
```

1. LibreLane + Magic produces `ring.spice` (transistors + parasitics)
2. yosys produces `synth.v`
3. Icarus compiles `synth.v` + the PDK cell models to `synth.vvp`.
4. `generate_cosim_tb.py` emits `cosim_tb.spice`, which connects everything together and uses `adc_bridge`/`dac_bridge` cells to connect the Verilog to the SPICE.
5. ngspice runs the testbench. Its `d_cosim` model runs the `.vvp` through `ivlng`.

All artifacts go in a per-`(cfg, corner)` dir, `build/<cfg>/<corner>/`, so independent sims run in parallel.
