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

// adpll_post_divider
//
// Staszewski & Balsara, Wiley 2006, Ch. 6 (DCO edge divider).
// Divides the DCO clock by an integer so the synthesizer can reach frequencies below the DCO's own
// band (clk_o = F_DCO / divide). Sits outside the loop, so it never affects lock.
//
// Parameters:
//   - DivisorWidth : bit-width of the divisor input
// Ports:
//   - clk_i, rst_ni, enable_i : DCO clock, async reset, run enable
//   - divisor_i : divisor (0 or 1 passes the DCO clock straight through)
//   - clk_o    : divided clock, ~50% duty (high for floor(divide/2) DCO cycles)

module adpll_post_divider #(
    parameter int unsigned DivisorWidth = 8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,

    input  logic                    enable_i,
    input  logic [DivisorWidth-1:0] divisor_i,
    output logic                    clk_o
);

logic [DivisorWidth-1:0] count_d, count_q;
logic                   clk_div_d, clk_div_q;

wire passthrough = (divisor_i <= 1);
wire last_cycle  = (count_q == divisor_i - 1'b1);

assign count_d   = !enable_i ? '0 : (last_cycle ? '0 : count_q + 1'b1);
assign clk_div_d = !enable_i ? 1'b0 : (count_q < (divisor_i >> 1));   // high for the first half

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        count_q   <= '0;
        clk_div_q <= 1'b0;
    end else begin
        count_q   <= count_d;
        clk_div_q <= clk_div_d;
    end
end

assign clk_o = passthrough ? clk_i : clk_div_q;

endmodule
