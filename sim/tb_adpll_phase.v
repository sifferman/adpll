// SPDX-License-Identifier: Apache-2.0
//
// Testbench for the phase-domain ADPLL, assembled here (no "controller" wrapper) from:
//   ring DCO -> adpll_tdc_flash (sub-cycle phase) -> adpll_phase_detector (phase error)
//            -> adpll_loop_filter_proportionalintegral (proportionalintegral) -> adpll_lock_detector.
// Runs under Icarus (SYNTHESIS undefined) so the DCO and TDC compile their behavioural models.
// Unlike the frequency-locked tb_adpll, this loop nulls PHASE: the detector advances a reference
// phase by fcw_i each reference cycle and the variable phase by the DCO edge count plus the TDC
// fraction; the proportionalintegral loop filter drives that phase error to zero. The same adpll_loop_filter_proportionalintegral
// serves here and in the FLL -- only the error source (detector) and gains differ.
//
// 25 MHz reference (40 ns). The mux-tap behavioural ring (half-period 1346 + 87.1*tune ps, the
// SPICE-calibrated law) hits a ~6 ns DCO period near tune~=20, so F_DCO/F_ref = 40/6 = 6.667; in
// Q.PhaseWidth (PhaseWidth=6) that is fcw=427. Reports time-to-lock and the settled tune, PASSing on
// a sane mid-range code.

module tb_adpll_phase;
  localparam int unsigned NUM_TUNE = 7;
  localparam int unsigned PHASE_W  = 6;     // TDC fractional-phase resolution (adpll_tdc_flash.PhaseWidth)
  localparam int unsigned FCW_W    = 24;
  localparam int unsigned ERR_W    = 24;    // phase-error / accumulator width
  localparam int unsigned FCW      = 427;   // 6.667 * 2^PHASE_W  (targets tune ~= 20)

  reg clk = 1'b0;
  always #(20ns) clk = ~clk;          // 25 MHz reference (40 ns)

  reg rst_n  = 1'b1;
  reg enable = 1'b0;

  wire [NUM_TUNE-1:0]     tune;
  wire [NUM_TUNE-1:0]     lock_sample;
  wire                    lock;
  wire                    dco_clk;
  wire [PHASE_W-1:0]      tdc_phase;
  wire signed [ERR_W-1:0] error;
  wire                    valid;

  ring_dco_muxtap #(.NumTuneBits(NUM_TUNE)) u_dco (
      .enable_i(enable),
      .tune_i  (tune),
      .clk_o   (dco_clk)
  );

  adpll_tdc_flash #(.PhaseWidth(PHASE_W)) u_tdc (
      .clk_i    (clk),
      .rst_ni   (rst_n),
      .dco_clk_i(dco_clk),
      .phase_o  (tdc_phase)
  );

  adpll_phase_detector #(.FcwWidth(FCW_W), .PhaseWidth(PHASE_W), .ErrorWidth(ERR_W)) u_det (
      .clk_i      (clk),
      .rst_ni     (rst_n),
      .enable_i   (enable),
      .fcw_i      (FCW_W'(FCW)),
      .dco_clk_i  (dco_clk),
      .tdc_phase_i(tdc_phase),
      .error_o    (error),
      .valid_o    (valid)
  );

  // Type-II proportionalintegral: gentler gains than the FLL (Alpha=6/Beta=11), accumulator sized to the phase error.
  adpll_loop_filter_proportionalintegral #(
      .NumTuneBits(NUM_TUNE),
      .ErrorWidth (ERR_W),
      .AccWidth   (ERR_W),
      .AlphaShift (6),
      .BetaShift  (11)
  ) u_lf (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .enable_i     (enable),
      .valid_i      (valid),
      .error_i      (error),
      .tune_o       (tune),
      .lock_sample_o(lock_sample)
  );

  adpll_lock_detector #(.SampleWidth(NUM_TUNE), .MinSamplesForLock(8), .BandRadius(2)) u_ld (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .enable_i       (enable),
      .sample_valid_i (valid),
      .tuning_sample_i(lock_sample),
      .lock_o         (lock)
  );

  integer cycles = 0, enable_cycle = 0;

`ifdef VCD
  // -DVCD: dump all signals (phase accumulators, tdc_phase, tune, lock, dco_clk, ...) for GTKWave.
  initial begin
    $dumpfile("tb_adpll_phase.vcd");
    $dumpvars(0, tb_adpll_phase);
  end
`endif

  always @(posedge clk) begin
    cycles = cycles + 1;
    if (lock) begin
      $display("LOCKED @%0t ns : tune=%0d  lock_time=%0d ref-cycles", $time, tune, cycles - enable_cycle);
      if (tune > 1 && tune < (1<<NUM_TUNE)-2) $display("PASS: phase adpll locked, tune=%0d in-range", tune);
      else                                    $display("FAIL: phase adpll locked at a rail (tune=%0d)", tune);
      $finish;
    end
    if (cycles > 2_000_000) begin $display("FAIL: timeout, no lock (tune=%0d)", tune); $finish; end
  end

  initial begin
    rst_n = 1'b1; enable = 1'b0;
    #(2ns) rst_n = 1'b0;                 // async-reset pulse for the gated DCO-domain counter
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    enable = 1'b1;
    enable_cycle = cycles;
  end
endmodule
