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

// adpll_loop_filter_bangbang
//
// Ref: Hanumolu et al. (IEEE CICC 2007, Sec. IV-A), 1-bit/DFF-sign detector; Lee, Kundert &
// Razavi (IEEE JSSC 39(9), 2004), bang-bang dynamics.
// Bang-bang loop filter: steps the tune code by the SIGN of the error each sample (integer LSB
// steps), ignoring magnitude. Operates on any signed loop error (e.g. dco_edge_count - mul from
// adpll_freq_detector). Locks on the integral operating point, not the +-1 LSB limit cycle.
//
// Parameters:
//   - NumTuneBits : DCO tune-code width
//   - ErrorWidth  : signed error input width (only its sign is used)
//   - IntegralGain, ProportionalGain : per-sample LSB steps (sign-scaled)
// Ports: clk_i, rst_ni, enable_i, valid_i, error_i -> tune_o, lock_sample_o

module adpll_loop_filter_bangbang #(
    parameter  int unsigned NumTuneBits      = 7,
    parameter  int unsigned ErrorWidth       = 26,
    parameter  int unsigned IntegralGain     = 1,
    parameter  int unsigned ProportionalGain = 1
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

logic [NumTuneBits-1:0] integral_d, integral_q;   // integral path: the operating-point code
logic [NumTuneBits-1:0] tune_d, tune_q;           // proportionalintegral output to the DCO (integral + proportional)

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

always_comb begin
    logic signed [1:0] error_sign;
    case ({error_i > 0, error_i < 0})
        2'b10:   error_sign = 1;
        2'b01:   error_sign = -1;
        default: error_sign = 0;
    endcase

    integral_d = integral_q;
    tune_d     = tune_q;
    if (enable_i && valid_i) begin
        integral_d = NumTuneBits'(clamp(0, int'(integral_q) + error_sign * int'(IntegralGain),     int'(TuneMax)));
        tune_d     = NumTuneBits'(clamp(0, int'(integral_d) + error_sign * int'(ProportionalGain), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        integral_q <= '0;
        tune_q     <= '0;
    end else begin
        integral_q <= integral_d;
        tune_q     <= tune_d;
    end
end

assign tune_o        = tune_q;
assign lock_sample_o = integral_q;   // the clean operating point, not the +-1 LSB limit cycle

endmodule
