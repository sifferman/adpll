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

// adpll_tdc_flash (behavioural)
//
// SIM-ONLY behavioural model of adpll_tdc_flash. The real TDC in rtl/adpll_tdc_flash.sv is a structural flash
// delay line (adpll_cell_delay taps) -- correct for synthesis/SPICE but slow to simulate and needs
// the string-parameter cell tooling. The digital sims only need the sub-cycle phase, so they compile
// THIS instead (the TDC boundary, mirroring sim/ring_dco_behavioral.sv): it reads the elapsed time
// from the last DCO rising edge to the reference edge and divides by the measured DCO period -> a
// fraction of the cycle, scaled to the [0, 2*pi) phase code. Same ports/parameters as the structural
// module, so it swaps in directly. The delay-line tap resolution is physical -> measured in SPICE.

module adpll_tdc_flash #(
    parameter int unsigned PhaseWidth               = 6,
    // Accepted for interface parity with the structural TDC; this ideal $realtime model normalises to
    // one DCO period regardless, so the delay-line sizing knob has no effect here (it sets the real
    // full-scale, which only the extracted/SPICE TDC exposes).
    parameter int unsigned DelayCellsBetweenSamples = 1,
    // Match the structural TDC's snapshot decimation so sim sees the same (decimated) phase-update rate.
    parameter int unsigned SampleEveryN             = 1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    input  logic                  dco_clk_i,
    output logic [PhaseWidth-1:0] phase_o,
    output logic                  period_valid_o
);

// The ideal model measures the period directly, so coverage is always valid (the structural TDC, with
// its finite line, reports real coverage here).
assign period_valid_o = 1'b1;

realtime dco_rise_time, dco_rise_prev, dco_period;
initial begin
    dco_rise_time = 0.0;
    dco_rise_prev = 0.0;
    dco_period    = 2.0ns;   // seed (> 0) so the first divide is safe
end
always @(posedge dco_clk_i) begin
    dco_rise_prev = dco_rise_time;
    dco_rise_time = $realtime;
    if (dco_rise_time > dco_rise_prev)
        dco_period = dco_rise_time - dco_rise_prev;
end

// Sample-enable: pulse once every SampleEveryN reference cycles, matching the structural TDC so the
// behavioural sim reproduces the same decimated phase-update rate the loop sees in silicon.
localparam int unsigned SampDivW = (SampleEveryN <= 1) ? 1 : $clog2(SampleEveryN);
logic [SampDivW-1:0] sample_cnt;
logic                sample_en;
always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) sample_cnt <= '0;
    else sample_cnt <= (sample_cnt == SampDivW'(SampleEveryN - 1)) ? '0 : (sample_cnt + SampDivW'(1));
assign sample_en = (SampleEveryN <= 1) ? 1'b1 : (sample_cnt == '0);

logic [PhaseWidth-1:0] phase_q;
real frac_real;
always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        phase_q <= '0;
    end else if (sample_en) begin
        frac_real = (dco_period > 0.0) ? ($realtime - dco_rise_time) / dco_period : 0.0;
        if (frac_real < 0.0)   frac_real = 0.0;
        if (frac_real > 0.999) frac_real = 0.999;
        phase_q <= PhaseWidth'($rtoi(frac_real * (1 << PhaseWidth)));   // [0,1) cycle -> [0,2*pi) code
    end
end
assign phase_o = phase_q;

endmodule
