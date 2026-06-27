// Copyright (c) 2026 Ethan Sifferman
//
// Redistribution and use in source and binary forms, with or without modification, are permitted
// provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this list of
//    conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of
//    conditions and the following disclaimer in the documentation and/or other materials provided
//    with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors may be used to
//    endorse or promote products derived from this software without specific prior written
//    permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// ring_dco_behavioral
//
// SIM-ONLY behavioural models of the ring DCOs. The real DCOs in rtl/dco/ are purely structural
// (built from rtl/tech_cells/, selected by `Target`) -- correct for synthesis and SPICE, but a
// structural #-delay ring is slow to simulate and needs string-parameter tooling support. The
// digital simulations don't care how the ring is built, only how clk_o's frequency moves with
// tune_i; the ring's real frequency-vs-code curve is a physical property verified in SPICE.
//
// So the boundary is the DCO: testbenches compile THIS file instead of rtl/dco/ (and skip
// rtl/tech_cells/), keeping the detector / loop filter / lock detector / CSR -- the actual digital
// logic -- under test on stock Icarus, fast. Each module mirrors its structural namesake's port
// list and parameters (Target is accepted and ignored).
//
// === closed-form ring law (replaces the old smooth 1.0+0.1*tune curve and the readmem table) ===
// A ring oscillator's half-period is t_stage * N_stages, and each DCO variant tunes one of those:
// the mux-tap/thermometer rings move N_stages with the code (half-period ~LINEAR in tune -- the
// extracted mux-tap ring fits Hp = 1346 + 87*tune ps to ~1 ps RMS, and stops oscillating past its
// tap range), while the binary/coarse-fine rings load a fixed-length ring (half-period rises with
// the loaded code). So each module carries a closed-form law with a few physically-named,
// SPICE-calibrated parameters (HpBasePs, HpSlopePs, TuneOscMax) instead of a lookup table.
// NB: a monotonic closed-form law does NOT reproduce the binary ring's real multi-mode
// non-monotonicity -- that is a silicon pathology only the measured curve captures, and (verified)
// it did not improve the gate-level-cosim match, so it is intentionally dropped here.
//
// === why this makes the bang-bang "stutter" emerge instead of being scripted ===
// clk_o is a FREE-RUNNING oscillator, NOT phase-locked to the reference window the frequency
// detector counts over. So a given frequency lands as N edges in one window and N+1 in the next
// depending on sub-cycle phase -> the detector's error count dithers +-1 -> the bang-bang error
// sign flips -> the loop settles into a +-1 LSB limit cycle. That dither is the cosim's "stutter",
// and here it falls out of an honest free-running oscillator + the real (steep, for the mux-tap)
// curve through the same detector the loop uses -- not from any added logic. The gate-level cosim's
// ring is itself a deterministic transient (no thermal noise), so its stutter is exactly this
// quantisation effect; JitterPs optionally adds +-ps cycle-to-cycle jitter to study a genuinely
// noisy ring, but it is not needed for the stutter (default 0 = noise-free, like the cosim).
//
// Fidelity boundary: this reproduces the dither limit cycle (the "stutter") from the right
// mechanism, but NOT the gate-level acquisition transients -- the cosim's extra loop latency (the
// edge counter's clock-domain-crossing synchroniser) is what let an over-large gear-shift step
// overshoot into the rail, and that is not modelled by a free-running DCO. The gate-level cosim
// remains the sign-off environment.
`define ADPLL_RING_DCO_BEHAVIOURAL                                                                  \
    logic    clk_r = 1'b1;                                                                          \
    realtime half_period;                                                                           \
    always begin                                                                                    \
        if (!enable_i || tune_i > TuneOscMax) begin                                                 \
            clk_r = 1'b1; #(1.0ns);          /* disabled or NO-OSC: stalled */                      \
        end else begin                                                                              \
            half_period = (HpBasePs + HpSlopePs * real'(tune_i)) * 1ps                              \
                        + (((JitterPs > 0) ? (($random % (2*JitterPs + 1)) - JitterPs) : 0) * 1ps); \
            if (half_period < 1ps) half_period = 1ps;                                               \
            #(half_period) clk_r = ~clk_r;                                                          \
        end                                                                                         \
    end                                                                                             \
    assign clk_o = clk_r

module ring_dco_binary #(
    parameter int unsigned NumTuneBits = 7,
    // Ring law (SPICE-calibrated, typical corner). Binary ring loads a fixed-length ring: half-period
    // rises with the loaded code, spanning the extracted ~385..135 MHz. (Monotonic approximation; the
    // real binary ring is non-monotonic -- see header.)
    parameter real         HpBasePs    = 1300.0, // half-period at tune=0, ps
    parameter real         HpSlopePs   = 19.0,   // ps added per code
    parameter int unsigned TuneOscMax  = (1 << NumTuneBits) - 1, // all codes oscillate
    parameter int          JitterPs    = 0,      // +-ps cycle-to-cycle jitter (0 = noise-free, like cosim)
    parameter string       Target      = "behavioral"   // ignored (structural-DCO interface parity)
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL;
endmodule

module ring_dco_thermometer #(
    parameter int unsigned NumTuneBits = 7,
    // Thermometer ring: unary-weighted load -> clean monotonic curve (the "ideal" variant).
    parameter real         HpBasePs    = 1300.0,
    parameter real         HpSlopePs   = 19.0,
    parameter int unsigned TuneOscMax  = (1 << NumTuneBits) - 1,
    parameter int          JitterPs    = 0,
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL;
endmodule

module ring_dco_muxtap #(
    parameter int unsigned NumTuneBits = 7,
    // Mux-tap ring: the code selects where the loop closes (N_stages), so half-period is LINEAR in
    // tune and the ring stops oscillating past the tap range. Fitted to the extracted ring at the
    // typical corner: Hp = 1346 + 87.1*tune ps (1.0 ps RMS), oscillating codes 0..50.
    parameter real         HpBasePs    = 1346.0,
    parameter real         HpSlopePs   = 87.1,
    parameter int unsigned TuneOscMax  = 50,     // codes 51..127 do not oscillate (NO-OSC dead zone)
    parameter int          JitterPs    = 0,
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL;
endmodule

module ring_dco_coarsefine #(
    parameter int unsigned NumTuneBits = 7,
    // Coarse-fine ring: coarse field (tune high bits) + fine field; monotonic in the integer code.
    parameter real         HpBasePs    = 1300.0,
    parameter real         HpSlopePs   = 19.0,
    parameter int unsigned TuneOscMax  = (1 << NumTuneBits) - 1,
    parameter int          JitterPs    = 0,
    parameter int unsigned NumFineBits = 3,
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL;
endmodule

`undef ADPLL_RING_DCO_BEHAVIOURAL
