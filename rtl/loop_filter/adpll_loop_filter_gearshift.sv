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
//
// MaxGear / loop stability: this is a bang-bang loop, so the step size is the loop gain. The error
// is a frequency *count* over one detector window, and after a tune step the DCO needs time (analog
// ring + its loading) to slew to the new frequency before the next window measures it truthfully.
// If the step is large, the DCO can't settle within a window: the detector keeps reading the stale
// pre-step frequency, keeps stepping the same way, and the loop overshoots -- on a steep DCO it
// railed to the tune extreme (verified in the gate-level cosim: gear=5/step=32 ran tune 0->127 in a
// few windows, never reversing, then could not recover within the run). A small starting step keeps
// each frequency move settle-able within one window, so the sign feedback stays valid and the binary
// search converges. MaxGear=2 (step 4) is the largest that stays stable across all four ring DCOs in
// the cosim; coarser acquisition isn't worth losing lock on the steep mux-tap ring.

module adpll_loop_filter_gearshift #(
    parameter  int unsigned NumTuneBits = 7,
    parameter  int unsigned ErrorWidth  = 26,
    parameter  int unsigned MaxGear      = (NumTuneBits >= 2) ? 2 : 0,
    parameter  int unsigned UpshiftAfter = 4,   // consecutive same-direction steps before re-upshifting
    localparam int unsigned GearWidth    = $clog2(MaxGear + 1)
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
logic [3:0]             same_count_d, same_count_q;          // consecutive same-direction steps (upshift)

// Leaky-average of the tune code for the lock sample. At gear 0 the tune hunts +-1 LSB about the
// operating point; on a steep/nonlinear DCO that +-1 LSB is a large frequency swing, so the raw tune
// trips the lock detector's band. Averaging (1/2^LockAvgShift leaky integrator, like the bang-bang
// filter's integral path) presents the steady operating point to the lock detector instead.
localparam int unsigned LockAvgShift = 3;
logic [NumTuneBits+LockAvgShift-1:0] lock_acc_d, lock_acc_q;

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
    same_count_d    = same_count_q;
    lock_acc_d      = lock_acc_q;
    if (enable_i && valid_i)
        lock_acc_d = lock_acc_q - (lock_acc_q >> LockAvgShift) + (NumTuneBits+LockAvgShift)'(tune_q);
    if (enable_i && valid_i && error_sign != 0) begin
        if (previous_sign_q != 0 && error_sign != previous_sign_q) begin
            // reversal = the last step overshot -> downshift (halve the step); restart the run counter
            if (gear_q != 0) gear_d = gear_q - 1'b1;
            same_count_d = '0;
        end else begin
            // same direction for a while = stuck far from lock / crawling -> UPSHIFT (bigger step) to
            // re-acquire, so a noisy detector that derailed the search can't leave it crawling forever.
            if (int'(same_count_q) + 1 >= int'(UpshiftAfter) && gear_q < GearWidth'(MaxGear)) begin
                gear_d       = gear_q + 1'b1;
                same_count_d = '0;
            end else begin
                same_count_d = same_count_q + 4'd1;
            end
        end
        previous_sign_d = error_sign;
        tune_d          = NumTuneBits'(clamp(0, int'(tune_q) + int'(error_sign) * int'(step), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        tune_q          <= '0;
        gear_q          <= GearWidth'(MaxGear);
        previous_sign_q <= '0;
        same_count_q    <= '0;
        lock_acc_q      <= '0;
    end else begin
        tune_q          <= tune_d;
        gear_q          <= gear_d;
        previous_sign_q <= previous_sign_d;
        same_count_q    <= same_count_d;
        lock_acc_q      <= lock_acc_d;
    end
end

assign tune_o        = tune_q;
assign lock_sample_o = NumTuneBits'(lock_acc_q >> LockAvgShift);   // averaged tune (rejects +-1 LSB hunt)

endmodule
