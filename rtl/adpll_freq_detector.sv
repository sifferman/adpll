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

// adpll_freq_detector
//
// Frequency detector for an FLL: counts DCO edges over a window of window_length_i
// reference cycles (adpll_freq_counter) and subtracts the target, emitting the signed error
// (dco_edge_count - target) once per window. Feed error_o to any adpll_loop_filter_* loop filter;
// the loop drives the error to zero, i.e. F_DCO = (target/window_length) * F_clk_i.
//
// Parameters:
//   - MaxEdgesPerWindow : max DCO edges per window (sets EdgeCountWidth / mul width)
//   - MaxWindowSize     : max window length (sets WindowSizeWidth / div width)
//   - ErrorWidth        : output error width (EdgeCountWidth + 2, signed)
// Ports:
//   - clk_i, rst_ni, enable_i
//   - target_i        : target edges/window (multiply ratio N = mul)
//   - window_length_i : measurement window length, in reference cycles (divider M = div)
//   - dco_clk_i       : DCO clock being measured
//   - error_o         : signed frequency error (dco_edge_count - target), valid with valid_o
//   - valid_o         : one-cycle strobe marking a fresh error_o

module adpll_freq_detector #(
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    localparam int unsigned ErrorWidth        = EdgeCountWidth + 2
) (
    input  wire                       clk_i,
    input  wire                       rst_ni,
    input  wire                       enable_i,
    input  wire [EdgeCountWidth-1:0]  target_i,         // mul (multiply ratio N)
    input  wire [WindowSizeWidth-1:0] window_length_i,  // div (window length, reference cycles)
    input  wire                       dco_clk_i,

    output wire signed [ErrorWidth-1:0] error_o,
    output wire                         valid_o
);

wire [EdgeCountWidth-1:0] dco_edge_count;

adpll_freq_counter #(
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(MaxWindowSize)
) adpll_freq_counter (
    .clk_i,
    .rst_ni,
    .enable_i,
    .window_length_i,
    .dco_clk_i,
    .dco_edge_count_o(dco_edge_count),
    .sample_valid_o  (valid_o)
);

// freq high => measured > target => raise tune (more delay). Signed, headroom for the subtraction.
assign error_o = $signed({2'b0, dco_edge_count}) - $signed({2'b0, target_i});

endmodule
