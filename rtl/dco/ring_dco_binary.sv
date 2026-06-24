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

// ring_dco_binary
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 2-3 (ring DCO, delay tuning).
// All-standard-cell ring oscillator: a NAND gate gates/sustains oscillation and binary-weighted
// inverter-pair segments (one mux each) insert delay by the binary value of tune_i. The ring is
// purely structural -- built from rtl/tech_cells/ primitives, no behavioural fork. The `Target`
// parameter picks the cell library, so the SAME netlist drives synthesis (gf180mcu_as_sc_mcu7t3v3)
// and simulation (behavioral: the tech cells carry a #-delay, so the ring actually oscillates).
// The frequency-vs-code curve is illustrative in behavioural sim; SPICE gives the real one.
//
// Parameters:
//   - NumTuneBits : tune-code width (number of delay elements)
//   - Target      : tech-cell library ("gf180mcu_as_sc_mcu7t3v3" | "behavioral")
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

(* keep_hierarchy *)
module ring_dco_binary #(
    parameter int unsigned NumTuneBits = 7,
    parameter string       Target      = "behavioral"
) (
    input  logic                  enable_i,
    input  logic[NumTuneBits-1:0] tune_i,
    output logic                  clk_o
);

//   node[0]          = NAND2(enable_i, feedback)
//   node[i+1]        = mux2(bypass = node[i], delayed_i, S = tune_i[i])
//   feedback / clk_o = node[NumTuneBits]
wire feedback;
wire [NumTuneBits:0] node;

adpll_cell_nand2 #(.Target(Target)) adpll_cell_nand2 (
    .A (enable_i),
    .B (feedback),
    .Y (node[0])
);

for (genvar i_GEN = 0; i_GEN < NumTuneBits; i_GEN++) begin : delay_segment
    localparam int unsigned NumStages = (1 << i_GEN);
    wire [2*NumStages:0] d;
    assign d[0] = node[i_GEN];
    for (genvar j_GEN = 0; j_GEN < NumStages; j_GEN++) begin : inverter_pair
        adpll_cell_inv #(.Target(Target)) i_inv_a (
            .A (d[2*j_GEN]),
            .Y (d[2*j_GEN + 1])
        );
        adpll_cell_inv #(.Target(Target)) i_inv_b (
            .A (d[2*j_GEN + 1]),
            .Y (d[2*j_GEN + 2])
        );
    end
    adpll_cell_mux2 #(.Target(Target)) adpll_cell_mux2 (
        .A (node[i_GEN]),
        .B (d[2*NumStages]),
        .S (tune_i[i_GEN]),
        .Y (node[i_GEN + 1])
    );
end

assign feedback = node[NumTuneBits];
assign clk_o    = node[NumTuneBits];

endmodule
