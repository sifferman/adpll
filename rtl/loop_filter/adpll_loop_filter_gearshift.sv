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

// adpll_loop_filter_gearshift
//
// Ref: Da Dalt (IEEE TCAS-I 52(1), 2005, Sec. V), gear shifting.
// Adaptive-step bang-bang loop filter: steps the tune code by +/-(1 << gear) on the sign of the
// error; each error-sign reversal (an overshoot) downshifts a gear, halving the step. Acquisition
// is a coarse binary search that auto-refines to a +-1 LSB limit cycle (fast lock, no gain tuning).
// Operates on any signed loop error (only its sign is used).
//
// Parameters:
//   - NumTuneBits : DCO tune-code width
//   - ErrorWidth  : signed error input width (only its sign is used)
//   - MaxGear     : starting gear; initial step is 1 << MaxGear
// Ports: clk_i, rst_ni, enable_i, valid_i, error_i -> tune_o, lock_sample_o

module adpll_loop_filter_gearshift #(
    parameter  int unsigned NumTuneBits = 7,
    parameter  int unsigned ErrorWidth  = 26,
    parameter  int unsigned MaxGear     = (NumTuneBits >= 3) ? NumTuneBits - 2 : 0,
    localparam int unsigned GearWidth   = $clog2(MaxGear + 1)
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

logic [NumTuneBits-1:0] tune_d, tune_q;                       // gear-shifted accumulator = the tune code
logic [GearWidth-1:0]   gear_d, gear_q;                       // current gear; step = 1 << gear
logic signed [1:0]      previous_sign_d, previous_sign_q;     // last nonzero error sign (reversal detect)

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

always_comb begin
    logic signed [1:0]      error_sign;
    logic [NumTuneBits-1:0] step;
    case ({error_i > 0, error_i < 0})
        2'b10:   error_sign = 1;
        2'b01:   error_sign = -1;
        default: error_sign = 0;
    endcase
    step = NumTuneBits'(1 << gear_q);

    tune_d          = tune_q;
    gear_d          = gear_q;
    previous_sign_d = previous_sign_q;
    if (enable_i && valid_i && error_sign != 0) begin
        // An error-sign reversal means the last step overshot: downshift to halve the step.
        if (previous_sign_q != 0 && error_sign != previous_sign_q && gear_q != 0)
            gear_d = gear_q - 1'b1;
        previous_sign_d = error_sign;
        tune_d          = NumTuneBits'(clamp(0, int'(tune_q) + int'(error_sign) * int'(step), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        tune_q          <= '0;
        gear_q          <= GearWidth'(MaxGear);
        previous_sign_q <= '0;
    end else begin
        tune_q          <= tune_d;
        gear_q          <= gear_d;
        previous_sign_q <= previous_sign_d;
    end
end

assign tune_o        = tune_q;
assign lock_sample_o = tune_q;   // dithers +-1 LSB about the target once the gear reaches 0

endmodule
