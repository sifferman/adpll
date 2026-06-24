# ADPLL gate-level mixed-signal co-simulation (ngspice + Icarus Verilog)

Simulate only the **analog ring DCO** in ngspice (extracted transistor netlist, real physics) and the
**synthesized gf180 digital loop** (freq detector → loop filter → lock detector → post-divider) in
**Icarus Verilog**, coupled into a true closed loop through ngspice's `d_cosim` XSPICE code model via
the **`ivlng`** shim. This matches the chip's real analog/digital boundary (DCO = analog macro, rest =
synthesized standard cells) and keeps the ngspice matrix tiny — the ring is ~404 devices vs ~1450 for
the whole PLL.

The digital side is the **real gate-level netlist**, not a hand-written loop: `make` derives it from the
`adpll_<filter>_<dco>` wrapper with yosys (see below), so the cosim exercises the same cells the PnR
flow produces.

## Result

The closed loop **locks and holds**: extracted `ring_dco_binary` + a 200 MHz reference, mul/div = 12/8
(→ 300 MHz target), `lock_o` asserts at **t ≈ 62 ns** (≈22 ns after enable) and stays asserted through
the end of the run, in **~5.2 min** wall-clock for a 1000 ns transient (typical corner). The analog cost
is fixed at the ring no matter how much digital logic the loop grows.

## How the loop netlist is derived (no hand-written top)

`make` runs yosys (`-m slang`) on the wrapper with the ring DCO **black-boxed** (a generated 12-line
`build/ring_bb.v` stub — needed only because `read_slang --ignore-unknown-modules` rejects *parameter
overrides* on an unknown module). It then:

1. `delete t:ring_dco_binary` — drop the ring instance,
2. `expose -input w:dco_clk` — promote the ring's `clk_o` net to a **top input** `dco_clk`,
3. `synth … -flatten; dfflibmap; abc -liberty` — map the loop to gf180 cells,
4. `write_verilog` — the gate-level loop, with `dco_clk` as the analog boundary input and
   `debug_dco_tune_o` as the tune output.

That netlist + the PDK's behavioural cell models (`$PDK_ROOT/.../<scl>.v`) compile to a `vvp` that
ngspice drives through `ivlng`.

## Files

- `Makefile` — the whole flow as file targets (so only what changed rebuilds); artifacts go in `build/`.
- `gen_ivlng_deck.py` — generates the ngspice deck from the gate netlist + the ring `.subckt`: ties
  `ref_mul_i`/`ref_div_i`/`post_div_i` to constant rails, wires the adc/dac bridges and the ring, and
  emits the `d_cosim` port vector in module-declaration order (each bus **MSB-first**).
- `build/` (git-ignored) — generated: `ring_bb.v`, hardened `ring.spice`, `<cfg>_gl.v`, the `vvp`,
  the deck, and the run log.

## Run

    # one config at one corner — inside the nix devshell, with an enabled gf180 PDK at $PDK_ROOT:
    nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical \
        PDK_ROOT=$PDK_ROOT IVL_PREFIX=/path/to/iverilog-libvvp
    # -> build/adpll_bangbang_binary_typical.log + "LOCKED (t_lock=...)" / "NO-LOCK"

**REQUIREMENT:** `iverilog`/`vvp` must be built with `--enable-libvvp` (ivlng `dlopen`s `libvvp` and runs
`vvp`). Point `IVL_PREFIX` at that install. ngspice resolves the transistor models via `$PDK_ROOT`,
which it expands inside the `.lib`/`.include` *file paths* (the corner is a literal section name baked
into the deck by `--corner`).

## Gotchas (each one cost a debugging cycle — read before editing)

1. **The `d_cosim` port vector is module-declaration order, and every bus is MSB-first** — verified
   empirically against `ivlng` (a constant-output probe: the first bracket slot carries the MSB, for
   both inputs and outputs). `gen_ivlng_deck.py` encodes this; if you wire a vector by hand, the first
   slot of `[…]` is the MSB.
2. **Rebuild the `vvp` after any RTL change.** A stale `vvp` silently simulates the old logic — the
   smoke `dff2` sat at `q=0` until rebuilt. (File targets in the Makefile handle this for you.)
3. **The loop `.v` needs a `` `timescale ``** or `vvp` runs at 1 s precision and nothing toggles; the
   Makefile prepends a `timescale.v` stub at compile.
4. **`ivlng` runtime libs.** ngspice loading `ivlng` needs `libvvp` plus the nix `bzip2`/`zlib`/
   `readline`/`gcc-14` libs on `LD_LIBRARY_PATH` — **appended** to the devshell's, never replacing it
   (replacing it breaks `digital.cm` loading → `d_cosim` becomes an "unknown device type"). Do **not**
   add `/usr/lib` (it breaks the nix glibc). The Makefile assembles this for you.
5. **`adc_bridge` needs picosecond `rise_delay`/`fall_delay`** — the default 1 ns can't track the
   ~hundreds-of-MHz DCO; use `10p`.

## Status

Validated for `adpll_bangbang_binary` at the typical corner. The other 11 configs and the ss/ff corners
run the same `make` target (`ADPLL=`/`CORNER=`); a config locks only if the (shrunk) mul/div ratio is
reachable by that DCO at that corner.
