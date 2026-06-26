// SPDX-License-Identifier: Apache-2.0
//
// Survey testbench for the digital ADPLL: ring DCO + a frequency detector (adpll_freq_detector)
// + a loop filter + adpll_lock_detector, assembled here (there is no "controller" wrapper). Runs
// under Icarus (SYNTHESIS undefined) so the DCO compiles its behavioural clock model. Selects the
// filter and DCO variant with plusdefines (testbench-only, not RTL):
//   default              : adpll_loop_filter_bangbang (bang-bang) + ring_dco_binary (binary)
//   -DCTRL_PROPORTIONALINTEGRAL         : adpll_loop_filter_proportionalintegral (proportionalintegral)
//   -DCTRL_GEARSHIFT      : adpll_loop_filter_gearshift (adaptive-step)
//   -DDCO_THERM / -DDCO_MUXTAP / -DDCO_COARSEFINE : thermometer / mux-tap / coarse-fine DCO
//
// The loop drives F_DCO = (mul/div)*F_ref. With the behavioural DCO (half-period 1.0+0.1*tune ns)
// and a 25 MHz reference, mul=1707/div=256 targets tune ~= 20. Reports time-to-lock and the
// settled tune code, and PASSes if it locks in a sane mid-range code.

`ifndef JITTER_PS
  `define JITTER_PS 0    // DCO per-half-period jitter in ps; override with -DJITTER_PS=<n>
`endif
`ifndef DCO_TABLE
  `define DCO_TABLE ""   // real freq-vs-code lookup (ps) from SPICE; -DDCO_TABLE=\"file.mem\" to use it
`endif
// Freq-detector target/window + reference period -- override to match the cosim FLL operating point
// (e.g. -DMUL_VAL=12 -DDIV_VAL=8 -DCLK_HALF=2.5 reproduces the 300 MHz @ 200 MHz-ref small-window case).
`ifndef MUL_VAL  `define MUL_VAL  1707 `endif
`ifndef DIV_VAL  `define DIV_VAL  256  `endif
`ifndef CLK_HALF `define CLK_HALF 20   `endif
module tb_adpll;
  localparam int unsigned NUM_TUNE = 7;
  localparam int unsigned CNT_W    = 24;        // EdgeCountWidth (mul width)
  localparam int unsigned DIV_W    = 16;        // WindowSizeWidth (div width)
  localparam int unsigned ERR_W    = CNT_W + 2; // adpll_freq_detector.ErrorWidth
  localparam int unsigned MUL      = `MUL_VAL;  // target DCO edges per window (N)
  localparam int unsigned DIV      = `DIV_VAL;  // window length in ref cycles (M)

  // bang-bang/gearshift lock on a clean code (+-1 LSB); the proportionalintegral dithers a little more.
`ifdef CTRL_PROPORTIONALINTEGRAL
  localparam int unsigned LOCK_BAND = 2;
`else
  localparam int unsigned LOCK_BAND = 1;
`endif

  reg clk = 1'b0;
  always #(`CLK_HALF * 1ns) clk = ~clk;   // reference half-period (default 20 ns = 25 MHz)

  reg rst_n  = 1'b1;
  reg enable = 1'b0;

  wire [NUM_TUNE-1:0]     tune;
  wire [NUM_TUNE-1:0]     lock_sample;
  wire                    lock;
  wire                    dco_clk;
  wire signed [ERR_W-1:0] error;
  wire                    valid;

`ifdef DCO_THERM
  ring_dco_thermometer #(.NumTuneBits(NUM_TUNE), .JitterPs(`JITTER_PS), .DcoTable(`DCO_TABLE)) u_dco (
`elsif DCO_MUXTAP
  ring_dco_muxtap #(.NumTuneBits(NUM_TUNE), .JitterPs(`JITTER_PS), .DcoTable(`DCO_TABLE)) u_dco (
`elsif DCO_COARSEFINE
  ring_dco_coarsefine #(.NumTuneBits(NUM_TUNE), .JitterPs(`JITTER_PS), .DcoTable(`DCO_TABLE)) u_dco (
`else
  ring_dco_binary #(.NumTuneBits(NUM_TUNE), .JitterPs(`JITTER_PS), .DcoTable(`DCO_TABLE)) u_dco (
`endif
      .enable_i(enable),
      .tune_i  (tune),
      .clk_o   (dco_clk)
  );

  adpll_freq_detector #(.MaxEdgesPerWindow((1<<CNT_W)-1), .MaxWindowSize((1<<DIV_W)-1)) u_fe (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .enable_i       (enable),
      .target_i       (CNT_W'(MUL)),
      .window_length_i(DIV_W'(DIV)),
      .dco_clk_i      (dco_clk),
      .error_o        (error),
      .valid_o        (valid)
  );

`ifdef CTRL_PROPORTIONALINTEGRAL
  adpll_loop_filter_proportionalintegral        #(.NumTuneBits(NUM_TUNE), .ErrorWidth(ERR_W)) u_flt (
`elsif CTRL_GEARSHIFT
  adpll_loop_filter_gearshift #(.NumTuneBits(NUM_TUNE), .ErrorWidth(ERR_W)) u_flt (
`else
  adpll_loop_filter_bangbang  #(.NumTuneBits(NUM_TUNE), .ErrorWidth(ERR_W)) u_flt (
`endif
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .enable_i     (enable),
      .valid_i      (valid),
      .error_i      (error),
      .tune_o       (tune),
      .lock_sample_o(lock_sample)
  );

  adpll_lock_detector #(.SampleWidth(NUM_TUNE), .MinSamplesForLock(8), .BandRadius(LOCK_BAND)) u_ld (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .enable_i       (enable),
      .sample_valid_i (valid),
      .tuning_sample_i(lock_sample),
      .lock_o         (lock)
  );

  integer cycles = 0, enable_cycle = 0;

`ifdef VCD
  // -DVCD: dump all signals (tune, integral/gear, error, lock, dco_clk, ...) for GTKWave.
  initial begin
    $dumpfile("tb_adpll.vcd");
    $dumpvars(0, tb_adpll);
  end
`endif

`ifdef TRACE
  reg [NUM_TUNE-1:0] tune_prev = {NUM_TUNE{1'b1}};
  reg                trace_started = 1'b0;
  always @(posedge clk) if (enable) begin
    if (!trace_started || tune !== tune_prev) begin
      $display("TRACE %0d %0d", cycles - enable_cycle, tune);
      tune_prev     = tune;
      trace_started = 1'b1;
    end
  end
`endif

  always @(posedge clk) begin
    cycles = cycles + 1;
    if (lock) begin
      $display("LOCKED @%0t ns : tune=%0d  lock_time=%0d ref-cycles", $time, tune, cycles - enable_cycle);
      if (tune > 1 && tune < (1<<NUM_TUNE)-2) $display("PASS: adpll locked, tune=%0d in-range", tune);
      else                                    $display("FAIL: adpll locked at a rail (tune=%0d)", tune);
      $finish;
    end
    if (cycles > 2_000_000) begin $display("FAIL: timeout, no lock (tune=%0d)", tune); $finish; end
  end

  initial begin
    rst_n = 1'b1; enable = 1'b0;
    #(2ns) rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    enable = 1'b1;
    enable_cycle = cycles;
  end
endmodule
