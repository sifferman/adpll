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

// adpll_tdc
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 6 (time-to-digital converter, flash delay line).
// Time-to-digital converter for the phase-domain ADPLL. At each reference edge (clk_i) it reports
// the DCO phase within the current cycle as an unsigned fixed-point angle: the range [0, 2*pi) is
// encoded across the full PhaseWidth-bit output, all-zeros = 0 and all-ones = just below 2*pi. The
// integer DCO phase is the edge count; this sub-cycle angle is what gives the loop its resolution.
// Structural: a flash delay line of adpll_cell_delay taps sampled by reference-clocked flops, then a
// thermometer popcount. The only PDK-specific piece is adpll_cell_delay (the delay tap); the samplers
// are plain flops. Sims compile sim/adpll_tdc_behavioral.sv instead (a fast $realtime model, stock
// Icarus, no PDK) -- the TDC boundary, mirroring sim/ring_dco_behavioral.sv.
//
// Parameters:
//   - PhaseWidth : phase resolution in bits; codes 0..2^PhaseWidth-1 span one cycle [0, 2*pi).
//                  The structural delay line is 2^PhaseWidth-1 taps.
// Ports:
//   - clk_i     : reference clock (the instant whose DCO phase is measured)
//   - rst_ni    : async-low reset (behavioural register only)
//   - dco_clk_i : DCO clock whose phase is measured
//   - phase_o   : DCO phase at the clk_i edge, [0, 2*pi) encoded 00..00 (0) to 11..11 (~2*pi)

module adpll_tdc #(
    parameter int unsigned PhaseWidth = 6
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    input  logic                  dco_clk_i,
    output logic [PhaseWidth-1:0] phase_o
);

localparam int unsigned NumTaps = (1 << PhaseWidth) - 1;

// Flash TDC: the DCO edge propagates down a delay line; the reference edge latches every tap at
// once, so the count of taps the edge has reached = elapsed DCO time in delay-cell units.
// NOTE: this is the raw delay-line count; a silicon build must back-annotate cell delays (SDF /
// SPICE) and size the line so 2^PhaseWidth-1 taps span one DCO period (a true Staszewski TDC also
// measures the period and divides to normalise -- left as a follow-up).
wire [NumTaps:0] tap;
assign tap[0] = dco_clk_i;
for (genvar i_GEN = 0; i_GEN < NumTaps; i_GEN++) begin : delay_line
    adpll_cell_delay #(.Target("gf180mcu_as_sc_mcu7t3v3")) adpll_cell_delay (
        .A (tap[i_GEN]),
        .Y (tap[i_GEN + 1])
    );
end

// Sample every tap on the reference edge (inferred flops; (* keep *) so they are not merged away).
(* keep *) logic [NumTaps-1:0] sampled;
always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) sampled <= '0;
    else         sampled <= tap[NumTaps:1];

function automatic logic [PhaseWidth-1:0] popcount(logic [NumTaps-1:0] taps);
    popcount = '0;
    for (int i = 0; i < NumTaps; i++)
        popcount += PhaseWidth'(taps[i]);
endfunction

logic [PhaseWidth-1:0] phase_comb;
always_comb phase_comb = popcount(sampled);
assign phase_o = phase_comb;

endmodule
