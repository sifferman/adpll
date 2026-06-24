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

// adpll_cell_mux
//
// 2:1 multiplexer (y = s ? b : a). In the ring DCOs it selects whether a delay segment is inserted
// (s = 1, y = b = delayed path) or bypassed (s = 0, y = a). One of the PDK-specific primitives in
// `rtl/cells/`; retarget a PDK by reimplementing this dir. PORT IT by swapping the instantiation
// below; keep the (* keep *)/(* dont_touch *) so the optimiser does not dissolve the ring path.
//
// Ports:
//   - a : input selected when s = 0
//   - b : input selected when s = 1
//   - s : select
//   - y : output (y = s ? b : a)

module adpll_cell_mux (
    input  wire a,
    input  wire b,
    input  wire s,
    output wire y
);

`ifdef SYNTHESIS
// --- gf180mcu 3.3 V (replace this instantiation for another PDK) ---
(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__mux2_2 u_cell (
    .A (a),
    .B (b),
    .S (s),
    .Y (y)
);
`else
// Functional model (see adpll_cell_inv on the zero-delay note).
assign y = s ? b : a;
`endif

endmodule
