# adpll — standalone all-digital ring-oscillator PLL IP. Self-contained Icarus sims (no PDK).
# DCO SPICE characterization (freq-vs-code) is being moved to OpenROAD/Magic parasitic extraction
# from the hardened ring_dco macros, replacing the former hand-written netlist generator.

SHELL := /bin/bash
# iverilog defaults to 1 s precision and rounds the behavioural #(1.0ns) delays to zero; set a
# 1ns/1ps default timescale via an iverilog command file (process substitution -- no source stub).
TS    = -c <(printf '+timescale+1ns/1ps\n')
# Shared core + all loop filters + the sim-only behavioural DCOs (single-PLL testbench picks one of
# each via plusdefines). The DCO boundary: sims use sim/ring_dco_behavioral.sv (a fast #-delay clock,
# stock Icarus, no PDK), NOT the structural rtl/dco/ + rtl/tech_cells/ (those are for synthesis/SPICE,
# where yosys+slang elaborates the `Target` string-parameter cells). The ring's real freq-vs-code
# curve is physical -> verified in SPICE, not here.
CORE  = $(wildcard rtl/*.sv rtl/loop_filter/*.sv) sim/ring_dco_behavioral.sv

.PHONY: help sim-adpll sim-adpll-survey sim-adpll-matrix sim-adpll-phase sim-adpll-csr clean
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-20s %s\n",$$1,$$2}'

sim-adpll: ## Standalone digital ADPLL: ring DCO (behavioural) + FLL lock (iverilog, no PDK)
	@mkdir -p sim_build
	iverilog -g2012 -o sim_build/tb_adpll $(TS) $(CORE) sim/tb_adpll.v
	vvp sim_build/tb_adpll

sim-adpll-survey: ## Compare the FLL loop filters (bang-bang / linear / gearshift): lock time + code
	@mkdir -p sim_build
	@for ctrl in "bang-bang:" "linear:-DCTRL_LINEAR" "gearshift:-DCTRL_GEARSHIFT"; do \
		name=$${ctrl%%:*}; def=$${ctrl#*:}; echo "==== loop filter: $$name ===="; \
		iverilog -g2012 $$def -o sim_build/tb_adpll_$$name $(TS) $(CORE) sim/tb_adpll.v && \
		vvp sim_build/tb_adpll_$$name | grep -E "LOCKED|PASS|FAIL"; \
	done

sim-adpll-matrix: ## All 12 FLL variants (3 loop filters x 4 DCOs): lock time + settled tune
	@mkdir -p sim_build
	@printf "%-26s %-12s %-8s %s\n" "config (filter x dco)" "lock_cyc" "tune" "result"
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
		rtl/adpll_freq_counter.sv rtl/adpll_lock_detector.sv rtl/adpll_tdc.sv rtl/adpll_phase_detector.sv \
		rtl/loop_filter/adpll_loop_filter_pi.sv sim/ring_dco_behavioral.sv sim/tb_adpll_phase.v
	vvp sim_build/tb_adpll_phase | grep -E "LOCKED|PASS|FAIL"

sim-adpll-csr: ## Single-PLL CSR: program mul/div/enable over AXI4-Lite, poll STATUS for lock
	@mkdir -p sim_build
	iverilog -g2012 -o sim_build/tb_adpll_csr $(TS) \
		rtl/axi/s_axi_adpll_csr.sv rtl/adpll_freq_detector.sv rtl/adpll_freq_counter.sv rtl/adpll_lock_detector.sv \
		rtl/loop_filter/adpll_loop_filter_bangbang.sv sim/ring_dco_behavioral.sv sim/tb_adpll_csr.v
	vvp sim_build/tb_adpll_csr | grep -E "CSR programmed|LOCKED|PASS|FAIL"

# ---- DCO SPICE characterisation (needs LibreLane + a gf180 PDK + ngspice >= 42) ----
# Harden one ring_dco_<DCO> as a standalone macro (librelane/ring_dco.yaml), then sweep its tune
# code through the Magic-extracted, parasitic netlist in ngspice -> frequency-vs-code, straight
# from the .sv via the real flow. Run inside the toolchain env (e.g. the LibreLane nix devshell or
# container). PDK_NGSPICE is auto-located under PDK_ROOT, so any ciel layout works.
PDK         ?= gf180mcuD
PDK_ROOT    ?= $(HOME)/.ciel
SCL         ?= gf180mcu_as_sc_mcu7t3v3
DCO         ?= ring_dco_binary
SWEEP       ?= 0,8,16,32,64,96,127
NGSPICE     ?= ngspice
PDK_NGSPICE ?= $(shell find $(PDK_ROOT) -type d -path '*/$(PDK)/libs.tech/ngspice' 2>/dev/null | head -1)
.PHONY: dco-spice
dco-spice: ## Harden a ring_dco macro + ngspice tune sweep (freq-vs-code). Needs LibreLane/PDK/ngspice.
	@test -n "$(PDK_NGSPICE)" || { echo "ERROR: PDK_NGSPICE empty -- no '*/$(PDK)/libs.tech/ngspice' under PDK_ROOT=$(PDK_ROOT). Is the PDK enabled?"; exit 1; }
	@echo "PDK_NGSPICE = $(PDK_NGSPICE)"
	librelane librelane/ring_dco.yaml --pdk $(PDK) --pdk-root $(PDK_ROOT) --scl $(SCL) -c DESIGN_NAME=$(DCO)
	python3 librelane/dco_freq.py \
		--extracted $$(ls -td librelane/runs/*/final/spice/$(DCO).spice | head -1) \
		--pdk-ngspice $(PDK_NGSPICE) --ngspice $(NGSPICE) --design $(DCO) --bits 7 --sweep $(SWEEP) \
		--out dco_freq.txt

clean: ## Remove sim build artifacts
	rm -rf sim_build
