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

// adpll_phase_detector
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 4-5 (phase-domain ADPLL phase detector).
// Phase detector for a true PLL. Each reference cycle it advances a reference phase by the
// frequency control word fcw_i (target DCO cycles per reference cycle, Q.PhaseWidth fixed point)
// and the variable phase by the DCO edge count (adpll_freq_counter, 1-cycle window) plus the
// sub-cycle phase from adpll_tdc; the signed difference is the phase error. Feed error_o to
// adpll_loop_filter_proportionalintegral -- nulling it phase-locks the DCO (F_DCO = fcw * F_clk_i).
//
// Parameters:
//   - MaxEdgesPerWindow : max DCO edges in one reference cycle (sizes the edge counter)
//   - FcwWidth          : frequency control word width (Q.PhaseWidth)
//   - PhaseWidth        : fractional-phase resolution (matches adpll_tdc); the fixed-point fraction bits
//   - ErrorWidth        : phase-error / accumulator width (holds the acquisition transient)
// Ports:
//   - clk_i, rst_ni, enable_i
//   - fcw_i       : frequency control word, F_DCO/F_clk_i in Q.PhaseWidth (runtime)
//   - dco_clk_i   : DCO clock feedback
//   - tdc_phase_i : sub-cycle DCO phase at this reference edge (from adpll_tdc), Q.PhaseWidth
//   - error_o     : signed phase error (variable phase - reference phase), valid with valid_o
//   - valid_o     : one-cycle strobe marking a fresh error_o

module adpll_phase_detector #(
    parameter  int unsigned MaxEdgesPerWindow = (1 << 12) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned FcwWidth          = 24,
    parameter  int unsigned PhaseWidth        = 6,
    parameter  int unsigned ErrorWidth        = 24
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    input  logic                  enable_i,
    input  logic [FcwWidth-1:0]   fcw_i,
    input  logic                  dco_clk_i,
    input  logic [PhaseWidth-1:0] tdc_phase_i,

    output logic signed [ErrorWidth-1:0] error_o,
    output logic                         valid_o
);

// Edges per single reference cycle (1-cycle measurement window), accumulated into the DCO phase.
wire [EdgeCountWidth-1:0] edges_this_cycle;
wire                      sample_valid;

adpll_freq_counter #(
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(1)
) adpll_freq_counter (
    .clk_i,
    .rst_ni,
    .enable_i,
    .window_length_i(1'b1),
    .dco_clk_i,
    .dco_edge_count_o(edges_this_cycle),
    .sample_valid_o  (sample_valid)
);

// phase_detector accumulates (integer DCO phase - reference phase), both Q.PhaseWidth; adding the
// TDC sub-cycle phase gives the full phase error (DCO ahead => positive => raise tune).
logic signed [ErrorWidth-1:0] phase_detector_d, phase_detector_q;

always_comb begin
    logic signed [ErrorWidth-1:0] phase_advance;   // DCO phase advance - reference phase advance
    phase_advance    = ErrorWidth'($signed({1'b0, edges_this_cycle}) <<< PhaseWidth) - ErrorWidth'(fcw_i);
    phase_detector_d = phase_detector_q;
    if (enable_i && sample_valid)
        phase_detector_d = phase_detector_q + phase_advance;
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) phase_detector_q <= '0;
    else         phase_detector_q <= phase_detector_d;
end

assign error_o = phase_detector_d + ErrorWidth'($signed({1'b0, tdc_phase_i}));
assign valid_o = sample_valid;

endmodule
