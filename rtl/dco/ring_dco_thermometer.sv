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

// ring_dco_thermometer
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 3 (thermometer coding / dynamic element
// matching).
// Ring oscillator tuned by a UNIT-weighted (thermometer) delay line: code k inserts k
// identical unit-pair delays, so the curve is monotonic by construction (2^N-1 units).
// Purely structural -- built from rtl/tech_cells/ primitives; the `Target` parameter picks the
// cell library (gf180mcu_as_sc_mcu7t3v3 for synth/SPICE, behavioral for sim). No behavioural fork.
//
// Parameters:
//   - NumTuneBits : tune-code width (number of delay elements)
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

(* keep_hierarchy *)
module ring_dco_thermometer #(
    parameter int unsigned NumTuneBits = 7,
    parameter string       Target      = "behavioral"
) (
    input  logic                   enable_i,
    input  logic [NumTuneBits-1:0] tune_i,
    output logic                   clk_o
);

localparam int unsigned NumUnits = (1 << NumTuneBits) - 1;

// Thermometer decode: unit_enable[k] = 1 iff k < tune_i.
wire [NumUnits-1:0] unit_enable;
for (genvar k_GEN = 0; k_GEN < NumUnits; k_GEN++) begin : decode
    assign unit_enable[k_GEN] = (k_GEN < tune_i);
end

wire feedback;
wire [NumUnits:0] node;

adpll_cell_nand2 #(.Target(Target)) adpll_cell_nand2 (
    .A (enable_i),
    .B (feedback),
    .Y (node[0])
);

for (genvar k_GEN = 0; k_GEN < NumUnits; k_GEN++) begin : delay_unit
    wire mid, delayed;
    adpll_cell_inv #(.Target(Target)) i_inv_a (
        .A (node[k_GEN]),
        .Y (mid)
    );
    adpll_cell_inv #(.Target(Target)) i_inv_b (
        .A (mid),
        .Y (delayed)
    );
    // Insert this unit's delay when its thermometer bit is set, else bypass.
    adpll_cell_mux2 #(.Target(Target)) adpll_cell_mux2 (
        .A (node[k_GEN]),
        .B (delayed),
        .S (unit_enable[k_GEN]),
        .Y (node[k_GEN + 1])
    );
end

assign feedback = node[NumUnits];
assign clk_o    = node[NumUnits];

endmodule
