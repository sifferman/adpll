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
// AXI4-Lite slave control/status registers for a single ADPLL. A host sets the synthesizer
// ratio (F_DCO = (mul/div)*F_clk) and enables the loop, and reads back lock + the live tune
// code. Single outstanding transaction. Port style follows alexforencich/verilog-axi
// (clk/rst active-high, DATA/ADDR/STRB params, aligned s_axil_* signals).
//
// Register map (word-addressed, byte offsets):
//   0x0 CTRL    [0]      enable          (R/W)
//   0x4 MUL     [EdgeCountWidth-1:0] mul (N)  (R/W)
//   0x8 DIV     [WindowSizeWidth-1:0] div (M) (R/W)
//   0xC STATUS  [0] lock, [NumTuneBits:1] tune (RO)

module s_axi_adpll_csr #(
    // Width of data bus in bits
    parameter  int unsigned DATA_WIDTH        = 32,
    // Width of address bus in bits
    parameter  int unsigned ADDR_WIDTH        = 32,
    // Width of wstrb (width of data bus in words)
    parameter  int unsigned STRB_WIDTH        = (DATA_WIDTH/8),
    // DCO tune-code width
    parameter  int unsigned NumTuneBits       = 7,
    // Max DCO edges per window (sets the mul field width)
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    // Max measurement window length (sets the div field width)
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1)
) (
    input  wire                   clk,
    input  wire                   rst,

    input  wire [ADDR_WIDTH-1:0]  s_axil_awaddr,
    input  wire [2:0]             s_axil_awprot,
    input  wire                   s_axil_awvalid,
    output wire                   s_axil_awready,
    input  wire [DATA_WIDTH-1:0]  s_axil_wdata,
    input  wire [STRB_WIDTH-1:0]  s_axil_wstrb,
    input  wire                   s_axil_wvalid,
    output wire                   s_axil_wready,
    output wire [1:0]             s_axil_bresp,
    output wire                   s_axil_bvalid,
    input  wire                   s_axil_bready,
    input  wire [ADDR_WIDTH-1:0]  s_axil_araddr,
    input  wire [2:0]             s_axil_arprot,
    input  wire                   s_axil_arvalid,
    output wire                   s_axil_arready,
    output wire [DATA_WIDTH-1:0]  s_axil_rdata,
    output wire [1:0]             s_axil_rresp,
    output wire                   s_axil_rvalid,
    input  wire                   s_axil_rready,

    output wire                   enable,
    output wire [EdgeCountWidth-1:0]  mul,
    output wire [WindowSizeWidth-1:0] div,
    input  wire                   lock,
    input  wire [NumTuneBits-1:0] tune
);

localparam int unsigned AddrLsb = $clog2(STRB_WIDTH);   // byte-within-word address bits

// mul/div are each written from one DATA_WIDTH register, so their fields must fit in it.
if (EdgeCountWidth  > DATA_WIDTH) $error("EdgeCountWidth exceeds DATA_WIDTH");
if (WindowSizeWidth > DATA_WIDTH) $error("WindowSizeWidth exceeds DATA_WIDTH");

logic                       ctrl_d, ctrl_q;   // CTRL[0] = enable
logic [EdgeCountWidth-1:0]  mul_d, mul_q;
logic [WindowSizeWidth-1:0] div_d, div_q;

// ---- write channel ----
logic       bvalid_d, bvalid_q;
wire        write_accept = s_axil_awvalid && s_axil_wvalid && (!bvalid_q || s_axil_bready);
wire [1:0]  write_index  = s_axil_awaddr[AddrLsb +: 2];

always_comb begin
    bvalid_d = bvalid_q;
    if (write_accept)       bvalid_d = 1'b1;
    else if (s_axil_bready) bvalid_d = 1'b0;
end

always_comb begin
    ctrl_d = ctrl_q;
    mul_d  = mul_q;
    div_d  = div_q;
    if (write_accept && s_axil_wstrb[0]) begin
        case (write_index)
            2'd0: ctrl_d = s_axil_wdata[0];
            2'd1: mul_d  = s_axil_wdata[EdgeCountWidth-1:0];
            2'd2: div_d  = s_axil_wdata[WindowSizeWidth-1:0];
            default: ;   // STATUS is read-only
        endcase
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        bvalid_q <= 1'b0;
        ctrl_q   <= 1'b0;
        mul_q    <= '0;
        div_q    <= '0;
    end else begin
        bvalid_q <= bvalid_d;
        ctrl_q   <= ctrl_d;
        mul_q    <= mul_d;
        div_q    <= div_d;
    end
end

assign s_axil_awready = write_accept;
assign s_axil_wready  = write_accept;
assign s_axil_bvalid  = bvalid_q;
assign s_axil_bresp   = 2'b00;

// ---- read channel ----
logic              rvalid_d, rvalid_q;
logic [DATA_WIDTH-1:0] rdata_d, rdata_q;
wire               read_accept = s_axil_arvalid && (!rvalid_q || s_axil_rready);
wire [1:0]         read_index  = s_axil_araddr[AddrLsb +: 2];

wire [DATA_WIDTH-1:0] status_word = {{(DATA_WIDTH-1-NumTuneBits){1'b0}}, tune, lock};

always_comb begin
    rvalid_d = rvalid_q;
    if (read_accept)        rvalid_d = 1'b1;
    else if (s_axil_rready) rvalid_d = 1'b0;
end

always_comb begin
    rdata_d = rdata_q;
    if (read_accept) begin
        case (read_index)
            2'd0:    rdata_d = {{(DATA_WIDTH-1){1'b0}}, ctrl_q};
            2'd1:    rdata_d = {{(DATA_WIDTH-EdgeCountWidth){1'b0}}, mul_q};
            2'd2:    rdata_d = {{(DATA_WIDTH-WindowSizeWidth){1'b0}}, div_q};
            default: rdata_d = status_word;
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

assign enable = ctrl_q;
assign mul    = mul_q;
assign div    = div_q;

endmodule
