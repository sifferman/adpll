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

// adpll_cell_nand
//
// 2-input NAND (y = ~(a & b)). In the ring DCOs this is the gating gate: it injects enable_i and
// supplies the single inversion that sustains oscillation (b = ring feedback). One of the
// PDK-specific primitives in `rtl/cells/`; retarget a PDK by reimplementing this dir. PORT IT by
// swapping the instantiation below; keep the (* keep *)/(* dont_touch *) so the optimiser does not
// dissolve the ring's combinational loop.
//
// Ports:
//   - a, b : inputs
//   - y    : output (y = ~(a & b))

module adpll_cell_nand (
    input  wire a,
    input  wire b,
    output wire y
);

`ifdef SYNTHESIS
// --- gf180mcu 3.3 V (replace this instantiation for another PDK) ---
(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__nand2_2 u_cell (
    .A (a),
    .B (b),
    .Y (y)
);
`else
// Functional model (see adpll_cell_inv on the zero-delay note).
assign y = ~(a & b);
`endif

endmodule
