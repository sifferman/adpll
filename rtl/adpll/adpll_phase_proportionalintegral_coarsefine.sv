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

// adpll_phase_proportionalintegral_coarsefine
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch.4-5 (phase-domain all-digital PLL); Kratyuk TCAS-II
// 2007 (type-II power-of-two alpha/beta proportional-integral loop); Staszewski Wiley 2006 Ch.2-3
// (binary-weighted delay select). See the detector / loop-filter / DCO source files for detail.
//
// One PHASE-domain ADPLL configuration = phase detector (TDC + reference/variable phase accumulators)
// + proportional-integral loop filter + coarsefine DCO, assembled from the generic adpll blocks (no
// "controller" wrapper). Unlike the frequency-locked adpll_<filter>_<dco> configs (which null average
// FREQUENCY via adpll_freq_detector), this nulls PHASE: the detector advances a reference phase by
// fcw_i each reference cycle and the variable phase by the DCO edge count plus the adpll_tdc_flash sub-cycle
// fraction; the type-II proportional-integral filter drives that phase error to zero, so
// F_DCO = fcw * F_clk_i with zero static phase error [Kratyuk2007 sec.IV: a second-order loop suffices].
//
// Parameterizable -- DcoNumTuneBits / TdcPhaseWidth / the FCW + error widths / loop-filter gains
// (AlphaShift/BetaShift) / the lock criterion size the tune code, phase resolution, accumulators and
// lock band. Defaults match the validated sim/tb_adpll_phase (7-bit tune, 6-bit TDC phase, Q.6 fcw,
// alpha=2^-6 / beta=2^-11). Each detector x loop-filter x DCO combination is its own module name (an
// RTL config elaborated inline, not a hardened macro).
//
// Ports:
//   - clk_i, rst_ni, enable_i : reference clock + run/program
//   - fcw_i      : frequency control word, F_DCO/F_clk_i in Q.TdcPhaseWidth fixed point (set over CSR)
//   - post_div_i : output divide K (set over CSR)
//   - clk_o            : synthesized output clock = F_DCO / K
//   - lock_o           : status (lock flag)
//   - debug_dco_tune_o : internal DCO tune code, debug observation only
//   - debug_dco_clk_o  : raw DCO clock, debug observation only

module adpll_phase_proportionalintegral_coarsefine #(
    parameter  int unsigned DcoNumTuneBits                 = 7,
    parameter  int unsigned TdcPhaseWidth                  = 6,
    parameter  int unsigned TdcDelayCellsBetweenSamples    = 1,
    parameter  int unsigned PhaseDetectorMaxEdgesPerWindow = (1 << 12) - 1,
    parameter  int unsigned PhaseDetectorFcwWidth          = 24,
    parameter  int unsigned PhaseDetectorErrorWidth        = 24,
    parameter  int unsigned LoopFilterAlphaShift           = 6,
    parameter  int unsigned LoopFilterBetaShift            = 11,
    parameter  int unsigned LockMinSamplesForLock          = 8,
    parameter  int unsigned LockBandRadius                 = 2,
    parameter  int unsigned PostDividerMaxDivide           = 255,
    localparam int unsigned PostDividerDivideWidth         = $clog2(PostDividerMaxDivide + 1)
) (
    input  logic                              clk_i,
    input  logic                              rst_ni,
    input  logic                              enable_i,
    input  logic [PhaseDetectorFcwWidth-1:0]  fcw_i,      // F_DCO/F_clk_i in Q.TdcPhaseWidth (set over CSR)
    input  logic [PostDividerDivideWidth-1:0] post_div_i, // output divide K (set over CSR)

    output logic                              clk_o,             // synthesized output = F_DCO / K
    output logic                              lock_o,

    output logic [DcoNumTuneBits-1:0]         debug_dco_tune_o,  // internal tune, debug only
    output logic                              debug_dco_clk_o    // raw DCO oscillation, debug
);


wire signed [PhaseDetectorErrorWidth-1:0] phase_error;
wire                                      phase_error_valid;
wire [DcoNumTuneBits-1:0]                 dco_tune;
wire [DcoNumTuneBits-1:0]                 lock_detector_sample;
wire [TdcPhaseWidth-1:0]                  tdc_phase;
wire                                      dco_clk;

// TDC: sub-cycle DCO phase sampled at the reference edge (flash delay line in synthesis; behavioural
// $realtime model in iverilog -- same module name, file picked at build time, like the DCO).
adpll_tdc_flash #(
    .PhaseWidth(TdcPhaseWidth),
    .DelayCellsBetweenSamples(TdcDelayCellsBetweenSamples)
) adpll_tdc_flash (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .dco_clk_i(dco_clk),
    .phase_o  (tdc_phase),
    .period_valid_o()
);

// phase detector: reference phase (+= fcw_i) - variable phase (DCO edge count + TDC fraction) -> error
adpll_phase_detector #(
    .MaxEdgesPerWindow(PhaseDetectorMaxEdgesPerWindow),
    .FcwWidth         (PhaseDetectorFcwWidth),
    .PhaseWidth       (TdcPhaseWidth),
    .ErrorWidth       (PhaseDetectorErrorWidth)
) adpll_phase_detector (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .enable_i   (enable_i),
    .fcw_i      (fcw_i),
    .dco_clk_i  (dco_clk),
    .tdc_phase_i(tdc_phase),
    .error_o    (phase_error),
    .valid_o    (phase_error_valid)
);

// type-II loop filter: maps the phase error to the DCO tune code
adpll_loop_filter_proportionalintegral #(
    .NumTuneBits(DcoNumTuneBits),
    .ErrorWidth (PhaseDetectorErrorWidth),
    .AccWidth   (PhaseDetectorErrorWidth),
    .AlphaShift (LoopFilterAlphaShift),
    .BetaShift  (LoopFilterBetaShift)
) adpll_loop_filter_proportionalintegral (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .enable_i     (enable_i),
    .valid_i      (phase_error_valid),
    .error_i      (phase_error),
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
    .sample_valid_i (phase_error_valid),
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
    .clk_i    (dco_clk),
    .rst_ni   (rst_ni),
    .enable_i (enable_i),
    .divisor_i(post_div_i),
    .clk_o    (clk_o)
);

assign debug_dco_tune_o = dco_tune;
assign debug_dco_clk_o  = dco_clk;

endmodule
