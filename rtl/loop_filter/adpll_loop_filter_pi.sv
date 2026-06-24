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

// adpll_loop_filter_pi
//
// Ref: Kratyuk, Hanumolu, Moon & Mayaram (IEEE TCAS-II 54(3), 2007), power-of-two alpha/beta PI.
// Proportional-integral loop filter: drives a signed error to zero and outputs the DCO tune code.
//   tune = clamp(0, (error >>> AlphaShift) + (integral >>> BetaShift), TuneMax),  integral += error
// with an anti-windup clamp on the integral. The error source is external, so this one filter
// serves both the linear FLL (error = dco_edge_count - mul, from adpll_freq_detector) and the
// phase-domain PLL (error = phase error, from adpll_phase_detector); only the widths/gains differ.
//
// Parameters:
//   - NumTuneBits : DCO tune-code width
//   - ErrorWidth  : signed error input width
//   - AccWidth    : integral accumulator width (anti-windup)
//   - AlphaShift  : proportional gain alpha = 2^-AlphaShift
//   - BetaShift   : integral     gain beta  = 2^-BetaShift
// Ports:
//   - clk_i, rst_ni, enable_i
//   - valid_i        : process error_i this cycle (a fresh measurement)
//   - error_i        : signed loop error
//   - tune_o         : DCO tune code
//   - lock_sample_o  : value for the lock detector to watch (the settled tune)

module adpll_loop_filter_pi #(
    parameter  int unsigned NumTuneBits = 7,
    parameter  int unsigned ErrorWidth  = 26,
    parameter  int unsigned AccWidth    = 19,
    parameter  int unsigned AlphaShift  = 10,
    parameter  int unsigned BetaShift   = 8
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         enable_i,
    input  logic                         valid_i,
    input  logic signed [ErrorWidth-1:0] error_i,

    output logic [NumTuneBits-1:0] tune_o,
    output logic [NumTuneBits-1:0] lock_sample_o
);

localparam int unsigned TuneMax = (1 << NumTuneBits) - 1;
// Anti-windup limit: keep beta*accumulator inside the tune range.
localparam logic signed [AccWidth-1:0] AccMax = AccWidth'(TuneMax) <<< BetaShift;

// The PI sum is clamped through `int`; guard it cannot overflow that type.
if (AccWidth + 2 > $bits(int)) $error("AccWidth+2 exceeds int width");

logic signed [AccWidth-1:0] accumulator_d, accumulator_q;   // integral accumulator (anti-windup)
logic [NumTuneBits-1:0]     tune_d, tune_q;                 // PI output to the DCO

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

always_comb begin
    logic signed [AccWidth-1:0] accumulator_sum;
    logic signed [AccWidth+1:0] control_word;      // alpha*error + beta*accumulator
    accumulator_sum = '0;
    control_word    = '0;
    accumulator_d   = accumulator_q;
    tune_d          = tune_q;
    if (enable_i && valid_i) begin
        accumulator_sum = accumulator_q + AccWidth'(error_i);
        accumulator_d   = (accumulator_sum < 0)      ? '0 :
                          (accumulator_sum > AccMax) ? AccMax : accumulator_sum;
        // gains are arithmetic right shifts (alpha = 2^-AlphaShift, beta = 2^-BetaShift)
        control_word    = (AccWidth+2)'(error_i >>> AlphaShift) + (AccWidth+2)'(accumulator_d >>> BetaShift);
        tune_d          = NumTuneBits'(clamp(0, int'(control_word), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        accumulator_q <= '0;
        tune_q        <= '0;
    end else begin
        accumulator_q <= accumulator_d;
        tune_q        <= tune_d;
    end
end

assign tune_o        = tune_q;
assign lock_sample_o = tune_q;   // the PI loop settles to a near-static code; watch tune directly

endmodule
