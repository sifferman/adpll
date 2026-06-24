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

// adpll_gearshift_coarsefine
//
// Ref: Da Dalt TCAS-I 2005 (adaptive-step gear-shifting); Staszewski Wiley 2006 Ch.5 (coarse/fine normalized DCO). See the loop-filter / DCO source files for detail.
// One ADPLL configuration = gearshift loop filter + coarsefine DCO, assembled
// from the generic adpll blocks (detector -> loop filter -> DCO, plus lock detect; no "controller"
// wrapper). Parameterizable -- DcoNumTuneBits / FreqDetectorMaxEdgesPerWindow / FreqDetectorMaxWindowSize / the
// lock criterion (LockMinSamplesForLock / LockBandRadius) size the tune code, edge counter, window and lock band (defaults are the full-rate 7/24/16 config; shrink
// them for a fast closed-loop SPICE run). Each loop-filter x DCO combination is its own module name
// (an RTL config elaborated inline, not a hardened macro).
//
// Ports:
//   - clk_i, rst_ni, enable_i : run + program
//   - ref_mul_i, ref_div_i, post_div_i : synthesizer ratio N / M and output divide K (set over the CSR)
//   - clk_o            : synthesized output clock = F_DCO / K
//   - lock_o           : status (lock flag)
//   - debug_dco_tune_o : internal DCO tune code, debug observation only
//   - debug_dco_clk_o  : raw DCO clock, debug observation only

module adpll_gearshift_coarsefine #(
    parameter  int unsigned DcoNumTuneBits                = 7,
    parameter  int unsigned FreqDetectorMaxEdgesPerWindow = (1 << 24) - 1,
    parameter  int unsigned FreqDetectorMaxWindowSize     = (1 << 16) - 1,
    parameter  int unsigned LockMinSamplesForLock         = 8,
    parameter  int unsigned LockBandRadius                = 1,
    parameter  int unsigned PostDividerMaxDivide          = 255,
    localparam int unsigned FreqDetectorWindowSizeWidth   = $clog2(FreqDetectorMaxWindowSize + 1),
    localparam int unsigned LoopFilterErrorWidth          = $clog2(FreqDetectorMaxEdgesPerWindow + 1) + 2,
    localparam int unsigned PostDividerDivideWidth        = $clog2(PostDividerMaxDivide + 1)
) (
    input  logic                                              clk_i,
    input  logic                                              rst_ni,

    input  logic                                              enable_i,
    input  logic[$clog2(FreqDetectorMaxEdgesPerWindow+1)-1:0] ref_mul_i,  // target edge count N (set over CSR)
    input  logic[FreqDetectorWindowSizeWidth-1:0]             ref_div_i,  // window length M, ref cycles (CSR)
    input  logic[PostDividerDivideWidth-1:0]                  post_div_i,  // output divide K (set over CSR)

    output logic                                              clk_o,             // synthesized output = F_DCO / K
    output logic                                              lock_o,

    output logic[DcoNumTuneBits-1:0]                          debug_dco_tune_o,  // internal tune, debug only
    output logic                                              debug_dco_clk_o    // raw DCO oscillation, debug
);


wire signed [LoopFilterErrorWidth-1:0] loop_filter_error;
wire                                   loop_filter_error_valid;
wire [DcoNumTuneBits-1:0] dco_tune;
wire [DcoNumTuneBits-1:0] lock_detector_sample;
wire                                   dco_clk;

// detector: DCO edges over a ref_div_i window vs ref_mul_i -> signed frequency error
adpll_freq_detector #(
    .MaxEdgesPerWindow(FreqDetectorMaxEdgesPerWindow),
    .MaxWindowSize    (FreqDetectorMaxWindowSize)
) adpll_freq_detector (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .enable_i       (enable_i),
    .target_i       (ref_mul_i),
    .window_length_i(ref_div_i),
    .dco_clk_i      (dco_clk),
    .error_o        (loop_filter_error),
    .valid_o        (loop_filter_error_valid)
);

// loop filter: maps the frequency error to the DCO tune code
adpll_loop_filter_gearshift #(
    .NumTuneBits(DcoNumTuneBits),
    .ErrorWidth (LoopFilterErrorWidth)
) adpll_loop_filter_gearshift (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .enable_i     (enable_i),
    .valid_i      (loop_filter_error_valid),
    .error_i      (loop_filter_error),
    .tune_o       (dco_tune),
    .lock_sample_o(lock_detector_sample)
);

// lock detect: watches the settled tune sample
adpll_lock_detector #(
    .SampleWidth      (DcoNumTuneBits),
    .MinSamplesForLock(LockMinSamplesForLock),
    .BandRadius       (LockBandRadius)
) adpll_lock_detector (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .enable_i       (enable_i),
    .sample_valid_i (loop_filter_error_valid),
    .tuning_sample_i(lock_detector_sample),
    .lock_o         (lock_o)
);

ring_dco_coarsefine #(
    .NumTuneBits(DcoNumTuneBits),
    .Target("gf180mcu_as_sc_mcu7t3v3")
) ring_dco_coarsefine (
    .enable_i(enable_i),
    .tune_i  (dco_tune),
    .clk_o   (dco_clk)
);

adpll_post_divider #(
    .DivisorWidth(PostDividerDivideWidth)
) adpll_post_divider (
    .clk_i   (dco_clk),
    .rst_ni  (rst_ni),
    .enable_i(enable_i),
    .divisor_i(post_div_i),
    .clk_o   (clk_o)
);

assign debug_dco_tune_o = dco_tune;
assign debug_dco_clk_o  = dco_clk;

endmodule
