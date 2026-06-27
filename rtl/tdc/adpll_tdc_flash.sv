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

// adpll_tdc_flash
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 6 (time-to-digital converter, flash delay line).
// Time-to-digital converter for the phase-domain ADPLL. At each reference edge (clk_i) it reports the
// position of the DCO edge in a delay line: a count of phase units (each DelayCellsBetweenSamples cell
// delays). Sized so the line covers exactly one DCO period, that count is the sub-cycle phase; the
// integer DCO phase is the edge count, and this fraction gives the loop its resolution.
// Structural: a flash delay line of adpll_cell_delay taps sampled by reference-clocked flops, then a
// priority-encoder decode (first set tap = edge position). The only PDK-specific piece is
// adpll_cell_delay (the delay tap); the samplers are plain flops. Sims compile
// sim/adpll_tdc_behavioral.sv instead (a fast $realtime model, stock Icarus, no PDK) -- the TDC
// boundary, mirroring sim/ring_dco_behavioral.sv.
//
// PhaseWidth and DelayCellsBetweenSamples must be chosen together so the line covers one DCO period:
// full-scale = (2^PhaseWidth-1) * DelayCellsBetweenSamples * t_cell should be ~ one DCO period. Too
// short and phase_o saturates before the period ends; too long and only part of the range is used.
//
// Parameters:
//   - PhaseWidth               : phase resolution in bits; 2^PhaseWidth-1 sampled phase units.
//   - DelayCellsBetweenSamples : adpll_cell_delay cells between adjacent sampled taps. 1 = sample every
//                                cell (finest resolution, shortest full-scale); raising it stretches
//                                each phase unit by another cell delay so the line covers more DCO time.
// Ports:
//   - clk_i     : reference clock (the instant whose DCO phase is measured)
//   - rst_ni    : async-low reset (behavioural register only)
//   - dco_clk_i : DCO clock whose phase is measured
//   - phase_o        : normalised sub-cycle phase (frac / period * 2^PhaseWidth), a [0,1) fraction
//                      independent of cell delay and frequency
//   - period_valid_o : 1 when the line captured two DCO rising edges, i.e. it spans a full DCO period
//                      and the normalisation is valid. 0 = line too short for this frequency (raise
//                      DelayCellsBetweenSamples or PhaseWidth). Lets the design self-report coverage at
//                      runtime instead of needing the cell delay known ahead of time.

module adpll_tdc_flash #(
    parameter int unsigned PhaseWidth               = 6,
    parameter int unsigned DelayCellsBetweenSamples = 1,
    // Decimate the snapshot + decode to once every SampleEveryN reference cycles. The decode below is
    // a deep combinational chain (a NumPhaseUnits-wide priority encode plus a divide); on a fast
    // reference clock it cannot settle in one cycle. Snapshotting every SampleEveryN cycles gives it
    // SampleEveryN cycles to settle before phase_o is re-registered, so the timing path is a valid
    // SampleEveryN-cycle multicycle (declare it in the SDC). The phase loop bandwidth is far below the
    // reference rate, so a slower phase update is harmless. SampleEveryN=1 = original every-cycle behaviour.
    parameter int unsigned SampleEveryN             = 1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    input  logic                  dco_clk_i,
    output logic [PhaseWidth-1:0] phase_o,
    output logic                  period_valid_o
);

localparam int unsigned NumPhaseUnits = (1 << PhaseWidth) - 1;               // sampled taps
localparam int unsigned NumDelayCells = NumPhaseUnits * DelayCellsBetweenSamples;

// Flash TDC: the DCO edge propagates down a delay line; the reference edge latches the line at once,
// so the edge's position in the line = elapsed DCO time. Carefully pick DelayCellsBetweenSamples and
// PhaseWidth so the 2^PhaseWidth-1 phase units cover one DCO period.
wire [NumDelayCells:0] tap;
assign tap[0] = dco_clk_i;
for (genvar i_GEN = 0; i_GEN < NumDelayCells; i_GEN++) begin : delay_line
    adpll_cell_delay #(.Target("gf180mcu_as_sc_mcu7t3v3")) adpll_cell_delay (
        .A (tap[i_GEN]),
        .Y (tap[i_GEN + 1])
    );
end

// Sample-enable: pulse once every SampleEveryN reference cycles (always 1 when SampleEveryN<=1).
localparam int unsigned SampDivW = (SampleEveryN <= 1) ? 1 : $clog2(SampleEveryN);
logic [SampDivW-1:0] sample_cnt;
logic                sample_en;
always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) sample_cnt <= '0;
    else sample_cnt <= (sample_cnt == SampDivW'(SampleEveryN - 1)) ? '0 : (sample_cnt + SampDivW'(1));
assign sample_en = (SampleEveryN <= 1) ? 1'b1 : (sample_cnt == '0);

// Sample the phase-unit boundaries (every DelayCellsBetweenSamples-th node) on the reference edge,
// decimated by sample_en so the combinational decode below has SampleEveryN cycles to settle.
logic [NumPhaseUnits-1:0] sampled;
always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) sampled <= '0;
    else if (sample_en) for (int u = 0; u < NumPhaseUnits; u++)
        sampled[u] <= tap[(u + 1) * DelayCellsBetweenSamples];

// Self-normalising decode. Going down the line (back in time) each DCO rising edge is a 1->0 boundary
// (post-rise high, then pre-rise low). The first one is the fractional delay frac (ref edge -> most
// recent DCO rise); the spacing to the next is the DCO period -- both in the same phase units, so
// phase_o = frac/period * 2^PhaseWidth is a [0,1) fraction independent of cell delay (PVT) AND
// frequency. The line must span >= ~2 DCO periods (size it with DelayCellsBetweenSamples).
logic [NumPhaseUnits-1:0] rising_edge;
always_comb
    for (int u = 0; u < NumPhaseUnits; u++)
        rising_edge[u] = sampled[u] & (u == NumPhaseUnits - 1 ? 1'b0 : ~sampled[u + 1]);

logic [PhaseWidth-1:0] frac, second;
logic found_first, found_second;
always_comb begin
    frac = '0; second = '0; found_first = 1'b0; found_second = 1'b0;
    for (int u = 0; u < NumPhaseUnits; u++)
        if (rising_edge[u]) begin
            if      (!found_first)  begin frac   = PhaseWidth'(u); found_first  = 1'b1; end
            else if (!found_second) begin second = PhaseWidth'(u); found_second = 1'b1; end
        end
end

// period = spacing of the two most recent rising edges; fall back to full-scale if only one is in the
// line (keeps the divide safe and saturates the phase instead of blowing up).
logic [PhaseWidth:0]      period;
logic [2*PhaseWidth-1:0]  numer;
always_comb begin
    period = found_second ? ({1'b0, second} - {1'b0, frac}) : (PhaseWidth + 1)'(NumPhaseUnits);
    numer  = {{PhaseWidth{1'b0}}, frac} << PhaseWidth;
end
// Combinational decode of the current snapshot...
logic [PhaseWidth-1:0] phase_comb;
assign phase_comb = (period == 0) ? '0 : PhaseWidth'(numer / period);

// ...re-registered only on sample_en, i.e. after SampleEveryN cycles of settling from the snapshot.
// The path sampled -> {phase_o, period_valid_o} is therefore a SampleEveryN-cycle multicycle (see
// chip_top.sdc); only settled values are presented to the phase detector. (SampleEveryN=1 captures
// every cycle, matching the original combinational behaviour after one pipeline register.)
always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
        phase_o        <= '0;
        period_valid_o <= 1'b0;
    end else if (sample_en) begin
        phase_o        <= phase_comb;
        period_valid_o <= found_second;   // two rising edges captured => a full DCO period fits the line
    end

endmodule
