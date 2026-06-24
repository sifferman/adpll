# Gate-level mixed-signal co-simulation of one adpll config:
#   analog macro(s) in ngspice (extracted transistors) + the synthesized gf180 GATE loop run in Icarus
#   Verilog, coupled into a closed loop through ngspice's d_cosim XSPICE model via the `ivlng` shim.
#
# The loop netlist is DERIVED from the adpll wrapper by yosys -- no hand-written loop top. The analog
# parts are black-boxed and their boundary nets promoted to top ports; the rest maps to gf180 cells.
#   - FLL configs  (adpll_<filter>_<dco>):        ring DCO is analog; expose dco_clk.
#   - phase configs (adpll_phase_<filter>_<dco>): ring DCO AND the TDC are analog (the TDC's flash
#     delay line needs real cell delays); expose dco_clk + tdc_phase. fcw replaces mul/div.
# Each artifact is a file target; artifacts go in build/<cfg>/<corner>/ so sims run in parallel.
#
# Run inside the nix devshell with an enabled gf180 PDK at $PDK_ROOT, e.g.:
#   nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical
#   nix develop ../.. -c make -C cosim cosim ADPLL=adpll_phase_proportionalintegral_binary FCW=854
#
# REQUIREMENT: iverilog/vvp must be built with --enable-libvvp (ivlng dlopens libvvp and runs vvp).

ADPLL    ?= adpll_bangbang_binary
CORNER   ?= typical
MUL      ?= 12
DIV      ?= 8
FCW      ?= 427
POST_DIV ?= 1

PDK      ?= gf180mcuD
SCL      ?= gf180mcu_as_sc_mcu7t3v3
PDK_ROOT ?= $(HOME)/.ciel
LIB           := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/lib/$(SCL)__tt_025C_3v30.lib
PDK_SIM_CELLS := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/verilog/$(SCL).v

IVL_PREFIX ?= $(abspath $(dir $(shell command -v iverilog))/..)
IVERILOG   := $(IVL_PREFIX)/bin/iverilog
LIBVVP     := $(IVL_PREFIX)/lib/libvvp.so

# ivlng runtime deps: the libvvp build + the nix libs it (and ivlng.vpi) pull in.
NIXLIB = $(shell ls -d /nix/store/*$(1)*/lib 2>/dev/null | grep -v -- -dev | head -1)
IVLNG_LIBS := $(IVL_PREFIX)/lib:$(call NIXLIB,bzip2-1.0.8):$(call NIXLIB,zlib-1.3):$(call NIXLIB,readline-8.3):$(call NIXLIB,gcc-14)

RTL_DIR := ../rtl
IS_PHASE := $(if $(findstring adpll_phase_,$(ADPLL)),1,)

# adpll_<filter>_<dco> (FLL) vs adpll_phase_<filter>_<dco> (phase): the dco is the last '_' token,
# the filter the one before it. The phase loop adds a detector token, shifting the word indices.
ifeq ($(IS_PHASE),1)
  FILTER   := $(word 3,$(subst _, ,$(ADPLL)))
  DCONAME  := $(word 4,$(subst _, ,$(ADPLL)))
  DETECTOR := adpll_phase_detector
  REF_MHZ  ?= 25
  TSTOP    ?= 2000
else
  FILTER   := $(word 2,$(subst _, ,$(ADPLL)))
  DCONAME  := $(word 3,$(subst _, ,$(ADPLL)))
  DETECTOR := adpll_freq_detector
  REF_MHZ  ?= 200
  TSTOP    ?= 1000
endif
RINGDCO := ring_dco_$(DCONAME)

LOOP_RTL := $(RTL_DIR)/adpll/$(ADPLL).sv \
            $(RTL_DIR)/$(DETECTOR).sv \
            $(RTL_DIR)/adpll_freq_counter.sv \
            $(RTL_DIR)/loop_filter/adpll_loop_filter_$(FILTER).sv \
            $(RTL_DIR)/adpll_lock_detector.sv \
            $(RTL_DIR)/adpll_post_divider.sv

# Per-(config, corner) build dir so independent sims run in parallel without clobbering each other.
B         := build/$(ADPLL)/$(CORNER)
RING      := $(B)/ring.spice
RING_BB   := $(B)/ring_bb.v
TDC       := $(B)/tdc.spice
TDC_BB    := $(B)/tdc_bb.v
SYNTH_V   := $(B)/synth.v
SYNTH_VVP := $(B)/synth.vvp
TB        := $(B)/cosim_tb.spice
LOG       := $(B)/cosim.log

# Phase needs both macros (ring + TDC) black-boxed/extracted + tdc_phase exposed; FLL just the ring.
# FLL shrinks the freq detector's counters so it locks in few windows; the phase detector is already
# small (12-bit edge counter), so it needs no shrink.
ifeq ($(IS_PHASE),1)
  BB_FILES      := $(RING_BB) $(TDC_BB)
  ANALOG        := $(RING) $(TDC)
  SLANG_G       :=
  DETACH_DELETE := -p "delete t:$(RINGDCO)" -p "delete t:adpll_tdc_flash"
  DETACH_EXPOSE := -p "expose -input w:dco_clk w:tdc_phase"
  GEN_ARGS      := --phase --fcw $(FCW) --tdc-subckt adpll_tdc_flash
else
  BB_FILES      := $(RING_BB)
  ANALOG        := $(RING)
  SLANG_G       := -G FreqDetectorMaxEdgesPerWindow=255 -G FreqDetectorMaxWindowSize=15
  DETACH_DELETE := -p "delete t:$(RINGDCO)"
  DETACH_EXPOSE := -p "expose -input w:dco_clk"
  GEN_ARGS      := --mul $(MUL) --div $(DIV)
endif

.PHONY: cosim clean
.DELETE_ON_ERROR:

cosim: $(SYNTH_VVP) $(ANALOG)
	@test -e "$(LIBVVP)" || { echo "ERROR: $(LIBVVP) not found -- ivlng needs iverilog built --enable-libvvp. Set IVL_PREFIX=<that install>, or put a libvvp iverilog first on PATH."; exit 1; }
	./generate_cosim_tb.py \
	 --vvp synth.vvp \
	 --ring-subckt $(RINGDCO) \
	 --corner $(CORNER) \
	 --ref-mhz $(REF_MHZ) \
	 --post-div $(POST_DIV) \
	 --tstop-ns $(TSTOP) \
	 $(GEN_ARGS) > $(TB)
	@echo "== ngspice gate-level cosim ($(ADPLL) @ $(CORNER)) =="
	cd $(B) && \
	 env -u DISPLAY \
	  PDK_ROOT=$(PDK_ROOT) \
	  LD_LIBRARY_PATH="$$LD_LIBRARY_PATH:$(IVLNG_LIBS)" \
	  PATH="$(IVL_PREFIX)/bin:$$PATH" \
	  ngspice -b $(notdir $(TB)) 2>&1 \
	 | tee $(notdir $(LOG)) \
	 | grep -aiE "t_lock|error|aborted" || true
	@t=$$(grep -aoE "t_lock *= *[0-9.eE+-]+" $(LOG) | head -1); \
	 if [ -n "$$t" ]; then \
	   echo "$(ADPLL) @ $(CORNER): LOCKED ($$t)"; \
	 else \
	   echo "$(ADPLL) @ $(CORNER): NO-LOCK"; \
	   exit 1; \
	 fi

# Blackbox stubs (header only) so read_slang accepts the wrapper's parameterized analog instantiations.
$(RING_BB): $(RTL_DIR)/dco/$(RINGDCO).sv
	mkdir -p $(dir $@)
	{ echo '(* blackbox *)'; sed -n '/^module/,/);/p' $<; echo endmodule; } > $@

$(TDC_BB): $(RTL_DIR)/tdc/adpll_tdc_flash.sv
	mkdir -p $(dir $@)
	{ echo '(* blackbox *)'; sed -n '/^module/,/);/p' $<; echo endmodule; } > $@

# Hardened + Magic-extracted analog macros (transistor netlists with parasitics). Heavy: run LibreLane.
$(RING): ../librelane/ring_dco.yaml
	mkdir -p $(dir $@)
	librelane ../librelane/ring_dco.yaml --pdk $(PDK) --pdk-root $(PDK_ROOT) --scl $(SCL) -c DESIGN_NAME=$(RINGDCO)
	cp $$(ls -td ../librelane/runs/*/final/spice/$(RINGDCO).spice | head -1) $@

$(TDC): ../librelane/adpll_tdc_flash.yaml
	mkdir -p $(dir $@)
	librelane ../librelane/adpll_tdc_flash.yaml --pdk $(PDK) --pdk-root $(PDK_ROOT) --scl $(SCL)
	cp $$(ls -td ../librelane/runs/*/final/spice/adpll_tdc_flash.spice | head -1) $@

# Derive the gate loop from the wrapper: black-box the analog macro(s), expose their boundary nets as
# top ports, map the rest to gf180 cells, write the netlist.
$(SYNTH_V): $(LOOP_RTL) $(BB_FILES)
	mkdir -p $(dir $@)
	yosys -m slang \
	 -p "read_slang --ignore-unknown-modules $(SLANG_G) $(BB_FILES) $(LOOP_RTL)" \
	 -p "hierarchy -top $(ADPLL)" \
	 $(DETACH_DELETE) \
	 $(DETACH_EXPOSE) \
	 -p "synth -top $(ADPLL) -flatten" \
	 -p "dfflibmap -liberty $(LIB)" \
	 -p "abc -liberty $(LIB)" \
	 -p "opt_clean -purge" \
	 -p "write_verilog -noattr $@"

$(SYNTH_VVP): $(SYNTH_V) $(PDK_SIM_CELLS)
	mkdir -p $(dir $@)
	printf '`timescale 1ns/1ps\n' > $(B)/timescale.v
	$(IVERILOG) -g2012 -o $@ $(B)/timescale.v $(SYNTH_V) $(PDK_SIM_CELLS)

clean:
	rm -rf build
