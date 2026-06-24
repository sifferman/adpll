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

// adpll_cell_nand2
//
// 2-input NAND (Y = ~(A & B)). In the ring DCOs this is the gating gate: it injects enable and
// supplies the single inversion that sustains oscillation (B = ring feedback). Ports mirror the
// gf180 cell (A, B, Y) so the wrapper is drop-in. The implementation is chosen by the `Target`
// string parameter, NOT by a `define:
//   - "gf180mcu_as_sc_mcu7t3v3" : the gf180 3.3 V standard cell, (* keep *)/(* dont_touch *) so the
//                                 optimiser does not dissolve the ring's combinational loop.
//   - "behavioral"              : an RTL model with a unit gate delay (so a structural ring
//                                 oscillates in sim).
// An unknown Target is a hard error ($fatal). PORT a new PDK by adding a branch here; nothing
// outside rtl/cells/ changes.
//
// Parameters:
//   - Target          : target library ("gf180mcu_as_sc_mcu7t3v3" | "behavioral")
//   - BehavioralDelay : behavioral gate delay (ignored for a real PDK cell)
// Ports:
//   - A, B : inputs
//   - Y    : output (Y = ~(A & B))

module adpll_cell_nand2 #(
    parameter string   Target          = "behavioral",
    parameter realtime BehavioralDelay = 0.1ns
) (
    input  wire A,
    input  wire B,
    output wire Y
);

if (Target == "gf180mcu_as_sc_mcu7t3v3") begin : g_gf180mcu_as_sc_mcu7t3v3
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__nand2_2 u_cell (
        .A (A),
        .B (B),
        .Y (Y)
    );
end else if (Target == "behavioral") begin : g_behavioral
    assign #(BehavioralDelay) Y = ~(A & B);
end else begin : g_invalid
    initial $fatal(1, "adpll_cell_nand2: unsupported Target \"%s\"", Target);
end

endmodule
