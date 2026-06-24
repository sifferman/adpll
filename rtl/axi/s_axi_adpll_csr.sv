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

// s_axi_adpll_csr
//
// AXI4-Lite slave control/status registers for a single ADPLL. A host sets the synthesizer ratio
// (clk_o = (ref_mul/ref_div/post_div)*F_clk) and enables the loop, then reads back lock + the live
// tune code. Single outstanding transaction. Port style follows alexforencich/verilog-axi.
//
// Register map (word-addressed, byte offsets):
//   0x0  CTRL     [0] enable                                (R/W)
//   0x4  REF_MUL  [EdgeCountWidth-1:0] ref_mul  (N)         (R/W)
//   0x8  REF_DIV  [WindowSizeWidth-1:0] ref_div (M)         (R/W)
//   0xC  STATUS   [0] lock, [NumTuneBits:1] tune            (RO)
//   0x10 POST_DIV [PostDividerDivideWidth-1:0] post_div (K) (R/W)

module s_axi_adpll_csr #(
    parameter  int unsigned DATA_WIDTH             = 32,
    parameter  int unsigned ADDR_WIDTH             = 32,
    localparam int unsigned STRB_WIDTH             = (DATA_WIDTH/8),
    // DCO tune-code width
    parameter  int unsigned NumTuneBits            = 7,
    // Max DCO edges per window (sets the ref_mul field width)
    parameter  int unsigned MaxEdgesPerWindow      = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth         = $clog2(MaxEdgesPerWindow + 1),
    // Max measurement window length (sets the ref_div field width)
    parameter  int unsigned MaxWindowSize          = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth        = $clog2(MaxWindowSize + 1),
    // Max output edge-divider ratio (sets the post_div field width)
    parameter  int unsigned PostDividerMaxDivide   = 255,
    localparam int unsigned PostDividerDivideWidth = $clog2(PostDividerMaxDivide + 1)
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic [2:0]            s_axil_awprot,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,
    input  logic [DATA_WIDTH-1:0] s_axil_wdata,
    input  logic [STRB_WIDTH-1:0] s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,
    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,
    input  logic [ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic [2:0]            s_axil_arprot,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,
    output logic [DATA_WIDTH-1:0] s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready,

    output logic                              enable_o,
    output logic [EdgeCountWidth-1:0]         ref_mul_o,
    output logic [WindowSizeWidth-1:0]        ref_div_o,
    output logic [PostDividerDivideWidth-1:0] post_div_o,
    input  logic                              lock_i,
    input  logic [NumTuneBits-1:0]            tune_i
);

localparam int unsigned AddrLsb   = $clog2(STRB_WIDTH);   // byte-within-word address bits
localparam int unsigned RegIndexW = 3;                    // 5 registers -> 3-bit word index

// each field is written from one DATA_WIDTH register, so it must fit in it.
if (EdgeCountWidth         > DATA_WIDTH) $error("EdgeCountWidth exceeds DATA_WIDTH");
if (WindowSizeWidth        > DATA_WIDTH) $error("WindowSizeWidth exceeds DATA_WIDTH");
if (PostDividerDivideWidth > DATA_WIDTH) $error("PostDividerDivideWidth exceeds DATA_WIDTH");

logic                              ctrl_d, ctrl_q;   // CTRL[0] = enable
logic [EdgeCountWidth-1:0]         ref_mul_d, ref_mul_q;
logic [WindowSizeWidth-1:0]        ref_div_d, ref_div_q;
logic [PostDividerDivideWidth-1:0] post_div_d, post_div_q;

// ---- write channel ----
logic                  bvalid_d, bvalid_q;
wire                   write_accept = s_axil_awvalid && s_axil_wvalid && (!bvalid_q || s_axil_bready);
wire [RegIndexW-1:0]   write_index  = s_axil_awaddr[AddrLsb +: RegIndexW];

always_comb begin
    bvalid_d = bvalid_q;
    if (write_accept)       bvalid_d = 1'b1;
    else if (s_axil_bready) bvalid_d = 1'b0;
end

always_comb begin
    ctrl_d     = ctrl_q;
    ref_mul_d  = ref_mul_q;
    ref_div_d  = ref_div_q;
    post_div_d = post_div_q;
    if (write_accept && s_axil_wstrb[0]) begin
        case (write_index)
            3'd0: ctrl_d     = s_axil_wdata[0];
            3'd1: ref_mul_d  = s_axil_wdata[EdgeCountWidth-1:0];
            3'd2: ref_div_d  = s_axil_wdata[WindowSizeWidth-1:0];
            3'd4: post_div_d = s_axil_wdata[PostDividerDivideWidth-1:0];
            default: ;   // 3'd3 STATUS is read-only
        endcase
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        bvalid_q   <= 1'b0;
        ctrl_q     <= 1'b0;
        ref_mul_q  <= '0;
        ref_div_q  <= '0;
        post_div_q <= 1'b1;   // ÷1 passthrough out of reset
    end else begin
        bvalid_q   <= bvalid_d;
        ctrl_q     <= ctrl_d;
        ref_mul_q  <= ref_mul_d;
        ref_div_q  <= ref_div_d;
        post_div_q <= post_div_d;
    end
end

assign s_axil_awready = write_accept;
assign s_axil_wready  = write_accept;
assign s_axil_bvalid  = bvalid_q;
assign s_axil_bresp   = 2'b00;

// ---- read channel ----
logic                 rvalid_d, rvalid_q;
logic [DATA_WIDTH-1:0] rdata_d, rdata_q;
wire                  read_accept = s_axil_arvalid && (!rvalid_q || s_axil_rready);
wire [RegIndexW-1:0]  read_index  = s_axil_araddr[AddrLsb +: RegIndexW];

wire [DATA_WIDTH-1:0] status_word = {{(DATA_WIDTH-1-NumTuneBits){1'b0}}, tune_i, lock_i};

always_comb begin
    rvalid_d = rvalid_q;
    if (read_accept)        rvalid_d = 1'b1;
    else if (s_axil_rready) rvalid_d = 1'b0;
end

always_comb begin
    rdata_d = rdata_q;
    if (read_accept) begin
        case (read_index)
            3'd0:    rdata_d = {{(DATA_WIDTH-1){1'b0}}, ctrl_q};
            3'd1:    rdata_d = {{(DATA_WIDTH-EdgeCountWidth){1'b0}}, ref_mul_q};
            3'd2:    rdata_d = {{(DATA_WIDTH-WindowSizeWidth){1'b0}}, ref_div_q};
            3'd4:    rdata_d = {{(DATA_WIDTH-PostDividerDivideWidth){1'b0}}, post_div_q};
            default: rdata_d = status_word;   // 3'd3 STATUS
        endcase
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        rvalid_q <= 1'b0;
        rdata_q  <= '0;
    end else begin
        rvalid_q <= rvalid_d;
        rdata_q  <= rdata_d;
    end
end

assign s_axil_arready = read_accept;
assign s_axil_rdata   = rdata_q;
assign s_axil_rvalid  = rvalid_q;
assign s_axil_rresp   = 2'b00;

assign enable_o   = ctrl_q;
assign ref_mul_o  = ref_mul_q;
assign ref_div_o  = ref_div_q;
assign post_div_o = post_div_q;

endmodule
