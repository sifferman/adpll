# adpll — standalone all-digital ring-oscillator PLL IP. Self-contained Icarus sims (no PDK).
# DCO SPICE characterization needs a PDK: pass PDK_ROOT/PDK/NGSPICE (see dco-spice).

SHELL := /bin/bash
# iverilog defaults to 1 s precision and rounds the behavioural #(1.0ns) delays to zero; set a
# 1ns/1ps default timescale via an iverilog command file (process substitution -- no source stub).
TS    = -c <(printf '+timescale+1ns/1ps\n')
# Shared core + all controllers + all DCOs (single-PLL testbench picks one of each via plusdefines)
CORE  = $(wildcard rtl/*.sv rtl/controller/*.sv rtl/dco/*.sv)
NGSPICE ?= ngspice

.PHONY: help sim-adpll sim-adpll-survey sim-adpll-matrix sim-adpll-phase sim-adpll-csr dco-spice clean
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-20s %s\n",$$1,$$2}'

sim-adpll: ## Standalone digital ADPLL: ring DCO (behavioural) + FLL lock (iverilog, no PDK)
	@mkdir -p sim_build
	iverilog -g2012 -o sim_build/tb_adpll $(TS) $(CORE) sim/tb_adpll.v
	vvp sim_build/tb_adpll

sim-adpll-survey: ## Compare the FLL controllers (bang-bang / linear / gearshift): lock time + code
	@mkdir -p sim_build
	@for ctrl in "bang-bang:" "linear:-DCTRL_LINEAR" "gearshift:-DCTRL_GEARSHIFT"; do \
		name=$${ctrl%%:*}; def=$${ctrl#*:}; echo "==== controller: $$name ===="; \
		iverilog -g2012 $$def -o sim_build/tb_adpll_$$name $(TS) $(CORE) sim/tb_adpll.v && \
		vvp sim_build/tb_adpll_$$name | grep -E "LOCKED|PASS|FAIL"; \
	done

sim-adpll-matrix: ## All 12 FLL variants (3 controllers x 4 DCOs): lock time + settled tune
	@mkdir -p sim_build
	@printf "%-26s %-12s %-8s %s\n" "config (ctrl x dco)" "lock_cyc" "tune" "result"
	@for ctrl in "bb:" "lin:-DCTRL_LINEAR" "gear:-DCTRL_GEARSHIFT"; do \
		for dco in "binary:" "therm:-DDCO_THERM" "muxtap:-DDCO_MUXTAP" "cfine:-DDCO_COARSEFINE"; do \
			cn=$${ctrl%%:*}; cd=$${ctrl#*:}; dn=$${dco%%:*}; dd=$${dco#*:}; \
			iverilog -g2012 $$cd $$dd -o sim_build/tb_mx_$${cn}_$${dn} $(TS) $(CORE) sim/tb_adpll.v 2>/dev/null && \
			out=$$(vvp sim_build/tb_mx_$${cn}_$${dn} 2>/dev/null); \
			cyc=$$(echo "$$out" | grep -oE "lock_time=[0-9]+" | grep -oE "[0-9]+"); \
			tune=$$(echo "$$out" | grep -oE "tune=[0-9]+ in-range" | grep -oE "[0-9]+"); \
			res=$$(echo "$$out" | grep -oE "PASS|FAIL" | head -1); \
			printf "%-26s %-12s %-8s %s\n" "$$cn x $$dn" "$${cyc:-N/A}" "$${tune:-N/A}" "$${res:-NO-LOCK}"; \
		done; \
	done

sim-adpll-phase: ## Phase-domain ADPLL (TDC + reference/variable phase accumulators): true phase lock
	@mkdir -p sim_build
	iverilog -g2012 -o sim_build/tb_adpll_phase $(TS) \
		rtl/adpll_freq_counter.sv rtl/adpll_lock_detect.sv rtl/adpll_tdc.sv \
		rtl/controller/adpll_controller_phase.sv rtl/dco/ring_dco_binary.sv sim/tb_adpll_phase.v
	vvp sim_build/tb_adpll_phase | grep -E "LOCKED|PASS|FAIL"

sim-adpll-csr: ## Single-PLL CSR: program mul/div/enable over AXI4-Lite, poll STATUS for lock
	@mkdir -p sim_build
	iverilog -g2012 -o sim_build/tb_adpll_csr $(TS) \
		rtl/csr/s_axi_adpll_csr.sv rtl/controller/adpll_controller_bangbang.sv rtl/adpll_freq_counter.sv \
		rtl/adpll_lock_detect.sv rtl/dco/ring_dco_binary.sv sim/tb_adpll_csr.v
	vvp sim_build/tb_adpll_csr | grep -E "CSR programmed|LOCKED|PASS|FAIL"

dco-spice: ## DCO freq-vs-code in ngspice. Requires: make dco-spice PDK_ROOT=... PDK=gf180mcuD NGSPICE=...
	python3 scripts/gen_ring_dco_spice.py --pdk-root $(PDK_ROOT) --pdk $(PDK) --ngspice $(NGSPICE) \
		--bits 7 --topology $(or $(TOPOLOGY),binary) --sweep 0,4,8,16,32,64,96,127 --run --workdir sim_build

clean: ## Remove sim build artifacts
	rm -rf sim_build
