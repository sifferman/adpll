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

// adpll_cell_mux2
//
// 2:1 multiplexer (Y = S ? B : A). In the ring DCOs it selects whether a delay segment is inserted
// (S = 1, Y = B = delayed path) or bypassed (S = 0, Y = A). Ports mirror the gf180 cell (A, B, S, Y)
// so the wrapper is drop-in. The implementation is chosen by the `Target` string parameter, NOT by
// a `define:
//   - "gf180mcu_as_sc_mcu7t3v3" : the gf180 3.3 V standard cell, (* keep *)/(* dont_touch *) so the
//                                 optimiser does not dissolve the ring path.
//   - "behavioral"              : an RTL model with a unit gate delay (so a structural ring
//                                 oscillates in sim).
// An unknown Target is a hard error ($fatal). PORT a new PDK by adding a branch here; nothing
// outside rtl/tech_cells/ changes.
//
// Parameters:
//   - Target          : target library ("gf180mcu_as_sc_mcu7t3v3" | "behavioral")
//   - BehavioralDelay : behavioral gate delay (ignored for a real PDK cell)
// Ports:
//   - A : input selected when S = 0
//   - B : input selected when S = 1
//   - S : select
//   - Y : output (Y = S ? B : A)

module adpll_cell_mux2 #(
    parameter string   Target          = "behavioral",
    parameter realtime BehavioralDelay = 0.1ns
) (
    input  wire A,
    input  wire B,
    input  wire S,
    output wire Y
);

if (Target == "gf180mcu_as_sc_mcu7t3v3") begin : gf180mcu_as_sc_mcu7t3v3
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__mux2_2 gf180mcu_as_sc_mcu7t3v3__mux2_2 (
        .A (A),
        .B (B),
        .S (S),
        .Y (Y)
    );
end else if (Target == "behavioral") begin : behavioral
    assign #(BehavioralDelay) Y = S ? B : A;
end else begin : invalid
    initial $fatal(1, "adpll_cell_mux2: unsupported Target \"%s\"", Target);
end

endmodule
