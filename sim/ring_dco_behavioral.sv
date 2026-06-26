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
// digital simulations don't care how the ring is built, only that clk_o's frequency falls with
// tune_i; the ring's real frequency-vs-code curve is a physical property verified in SPICE.
//
// So the boundary is the DCO: testbenches compile THIS file instead of rtl/dco/ (and skip
// rtl/tech_cells/), keeping the detector / loop filter / lock detector / CSR -- the actual digital
// logic -- under test on stock Icarus, fast. Each module mirrors its structural namesake's port
// list and parameters (Target is accepted and ignored) so a macro instantiates either interchangeably.
//
// half_period = 1.0ns + 0.1ns*tune_i (illustrative); >= 1.0ns > 0 so there is never a zero-delay
// loop. The numbers are not the silicon curve -- SPICE gives that.
//
// JitterPs: optional per-half-period timing jitter, uniform in +-JitterPs picoseconds (default 0 =
// ideal clock). This models the analog ring's cycle-to-cycle jitter, which adds noise to the freq
// detector's edge count -- the effect the smooth ideal model lacks. Used to study how the loop
// filters tolerate a noisy DCO (e.g. why gearshift, with no integrator to average the noisy error
// sign, degrades on a jittery ring while the integrating bang-bang does not).

// DcoTable: optional path to a $readmemh half-period(ps) lookup (128 codes) from the real extracted-
// ring SPICE sweep (sim/dco_table_from_sweep.py). When set, the ring REPLAYS the measured freq-vs-code
// -- multi-mode non-monotonicity, steep regions, and NO-OSC dead codes (table entry 0 = ring stalled)
// -- so the behavioural sim behaves like the cosim. When empty (default), the smooth illustrative
// curve (1.0+0.1*tune ns) is used.
`define ADPLL_RING_DCO_BEHAVIOURAL(NAME)                                       \
    logic    clk_r = 1'b1;                                                     \
    realtime half_period;                                                      \
    integer  hp_tbl [0:(1<<NumTuneBits)-1];                                    \
    integer  use_tbl = 0;                                                      \
    initial if (DcoTable != "") begin $readmemh(DcoTable, hp_tbl); use_tbl = 1; end \
    always begin                                                              \
        if (!enable_i) begin                                                   \
            clk_r = 1'b1; #(1.0ns);                                            \
        end else if (use_tbl && hp_tbl[tune_i] == 0) begin                     \
            clk_r = 1'b1; #(1.0ns);            /* NO-OSC code: ring stalled */ \
        end else begin                                                         \
            half_period = (use_tbl ? hp_tbl[tune_i] * 1ps : 1.0ns + 0.1ns * tune_i) \
                        + 1ps * ((JitterPs > 0) ? ($random % (JitterPs + 1)) : 0); \
            if (half_period < 1ps) half_period = 1ps;                          \
            #(half_period) clk_r = ~clk_r;                                     \
        end                                                                    \
    end                                                                        \
    assign clk_o = clk_r

module ring_dco_binary #(
    parameter int unsigned NumTuneBits = 7,
    parameter int          JitterPs    = 0,   // +-jitter per half-period, in ps (0 = ideal)
    parameter string       DcoTable    = "",  // real freq-vs-code lookup (ps); "" = smooth model
    parameter string       Target      = "behavioral"   // ignored (structural-DCO interface parity)
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL(binary);
endmodule

module ring_dco_thermometer #(
    parameter int unsigned NumTuneBits = 7,
    parameter int          JitterPs    = 0,   // +-jitter per half-period, in ps (0 = ideal)
    parameter string       DcoTable    = "",  // real freq-vs-code lookup (ps); "" = smooth model
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL(thermometer);
endmodule

module ring_dco_muxtap #(
    parameter int unsigned NumTuneBits = 7,
    parameter int          JitterPs    = 0,   // +-jitter per half-period, in ps (0 = ideal)
    parameter string       DcoTable    = "",  // real freq-vs-code lookup (ps); "" = smooth model
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL(muxtap);
endmodule

module ring_dco_coarsefine #(
    parameter int unsigned NumTuneBits = 7,
    parameter int          JitterPs    = 0,   // +-jitter per half-period, in ps (0 = ideal)
    parameter string       DcoTable    = "",  // real freq-vs-code lookup (ps); "" = smooth model
    parameter int unsigned NumFineBits = 3,
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);
    `ADPLL_RING_DCO_BEHAVIOURAL(coarsefine);
endmodule

`undef ADPLL_RING_DCO_BEHAVIOURAL
