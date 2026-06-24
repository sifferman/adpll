// Loop-only ADPLL top for ngspice d_cosim: detector + bang-bang filter + lock detector.
// The DCO is NOT here -- it lives in ngspice (analog ring). dco_clk_i arrives via an adc_bridge,
// tune_o leaves via a dac_bridge. mul/div are baked for the POC (target ~300 MHz at 200 MHz ref).
module adpll_loop_cosim (
    input  logic       clk_i,       // reference clock (from ngspice)
    input  logic       rst_ni,
    input  logic       enable_i,
    input  logic       dco_clk_i,   // DCO clock from the ngspice ring (via adc_bridge)
    output logic [6:0] tune_o,      // to the ngspice ring (via dac_bridge)
    output logic       lock_o
);
localparam int unsigned NumTuneBits       = 7;
localparam int unsigned MaxEdgesPerWindow = 255;
localparam int unsigned MaxWindowSize     = 15;
localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1);
localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1);
localparam int unsigned ErrorWidth        = EdgeCountWidth + 2;
localparam logic [EdgeCountWidth-1:0]  REF_MUL = 8'd12;   // target edge count N
localparam logic [WindowSizeWidth-1:0] REF_DIV = 4'd8;    // window length M (ref cycles)

wire signed [ErrorWidth-1:0] error;
wire                         valid;
wire [NumTuneBits-1:0]       tune, lock_sample;

adpll_freq_detector #(.MaxEdgesPerWindow(MaxEdgesPerWindow), .MaxWindowSize(MaxWindowSize)) det (
    .clk_i, .rst_ni, .enable_i, .target_i(REF_MUL), .window_length_i(REF_DIV),
    .dco_clk_i, .error_o(error), .valid_o(valid));
adpll_loop_filter_bangbang #(.NumTuneBits(NumTuneBits), .ErrorWidth(ErrorWidth)) lf (
    .clk_i, .rst_ni, .enable_i, .valid_i(valid), .error_i(error),
    .tune_o(tune), .lock_sample_o(lock_sample));
adpll_lock_detector #(.SampleWidth(NumTuneBits), .MinSamplesForLock(8), .BandRadius(1)) ld (
    .clk_i, .rst_ni, .enable_i, .sample_valid_i(valid), .tuning_sample_i(lock_sample), .lock_o(lock_o));
assign tune_o = tune;
`ifdef DBGPRINT
always @(posedge clk_i) if (enable_i && valid)
    $display("[loop] t=%0t err=%0d tune=%0d lock=%0d", $time, error, tune, lock_o);
`endif
endmodule
