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

// adpll_cell_delay
//
// One buffer-delay element: the unit tap of the TDC delay line, where the delay must be a real
// physical buffer (it cannot be inferred -- a synthesis tool would optimise a plain buffer away,
// and RTL has no notion of absolute delay). The LSB time is this cell's delay, characterised in
// SPICE. Ports mirror the gf180 cell (A, Y) so the wrapper is drop-in. The implementation is chosen
// by the `Target` string parameter, NOT by a `define:
//   - "gf180mcu_as_sc_mcu7t3v3" : the gf180 3.3 V delay buffer, (* keep *)/(* dont_touch *) so it
//                                 is preserved.
//   - "behavioral"              : an RTL model with a unit delay (a real, non-zero tap so a
//                                 structural delay line is exercisable in sim; the TDC's own sim
//                                 path uses a $realtime model).
// An unknown Target is a hard error ($fatal). PORT a new PDK by adding a branch here; nothing
// outside rtl/cells/ changes.
//
// Parameters:
//   - Target          : target library ("gf180mcu_as_sc_mcu7t3v3" | "behavioral")
//   - BehavioralDelay : behavioral tap delay (ignored for a real PDK cell, whose delay is the silicon's)
// Ports:
//   - A : input
//   - Y : delayed output (Y = A after one cell delay)

module adpll_cell_delay #(
    parameter string   Target          = "behavioral",
    parameter realtime BehavioralDelay = 0.1ns
) (
    input  wire A,
    output wire Y
);

if (Target == "gf180mcu_as_sc_mcu7t3v3") begin : g_gf180mcu_as_sc_mcu7t3v3
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__dlybuff_2 u_cell (
        .A (A),
        .Y (Y)
    );
end else if (Target == "behavioral") begin : g_behavioral
    assign #(BehavioralDelay) Y = A;
end else begin : g_invalid
    initial $fatal(1, "adpll_cell_delay: unsupported Target \"%s\"", Target);
end

endmodule
