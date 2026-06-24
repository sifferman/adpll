# Gate-level mixed-signal co-simulation of one adpll config:
#   analog ring DCO (ngspice, extracted transistors) + the synthesized gf180 GATE loop run in Icarus
#   Verilog, coupled into a closed loop through ngspice's d_cosim XSPICE model via the `ivlng` shim.
#
# The loop netlist is DERIVED from the adpll wrapper by yosys -- there is NO hand-written loop top:
# the ring DCO is black-boxed, its clk_o is promoted to a top input (`dco_clk`), tune stays as
# `debug_dco_tune_o`, and the loop (detector/filter/lock/post-divider) is mapped to gf180 cells.
# Each artifact below is a file target so `make` rebuilds only what changed. Artifacts go in a
# per-(config, corner) dir, build/<cfg>/<corner>/, so independent sims can run in parallel.
#
# Run inside the nix devshell with an enabled gf180 PDK at $PDK_ROOT, e.g.:
#   nix develop ../.. -c make -C cosim cosim ADPLL=adpll_bangbang_binary CORNER=typical
#
# REQUIREMENT: iverilog/vvp must be built with --enable-libvvp (ivlng dlopens libvvp and runs vvp).
# Point IVL_PREFIX at that install (default /tmp/iverilog-libvvp).

ADPLL    ?= adpll_bangbang_binary
CORNER   ?= typical
REF_MHZ  ?= 200
MUL      ?= 12
DIV      ?= 8
POST_DIV ?= 1

PDK      ?= gf180mcuD
SCL      ?= gf180mcu_as_sc_mcu7t3v3
PDK_ROOT ?= $(HOME)/.ciel
LIB           := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/lib/$(SCL)__tt_025C_3v30.lib
PDK_SIM_CELLS := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/verilog/$(SCL).v

# iverilog/vvp must be built --enable-libvvp (ivlng dlopens libvvp + runs vvp). Default to the install
# prefix of whatever `iverilog` is on PATH (the dir above its bin/). Override IVL_PREFIX if that build
# wasn't --enable-libvvp -- the cosim recipe checks lib/libvvp.so is actually there before running.
IVL_PREFIX ?= $(abspath $(dir $(shell command -v iverilog))/..)
IVERILOG   := $(IVL_PREFIX)/bin/iverilog
LIBVVP     := $(IVL_PREFIX)/lib/libvvp.so

# adpll_<filter>_<dco>: split on '_'. The filter token is exactly the loop-filter file suffix.
FILTER  := $(word 2,$(subst _, ,$(ADPLL)))
DCONAME := $(word 3,$(subst _, ,$(ADPLL)))
RINGDCO := ring_dco_$(DCONAME)

RTL_DIR  := ../rtl
LOOP_RTL := $(RTL_DIR)/adpll/$(ADPLL).sv \
            $(RTL_DIR)/adpll_freq_detector.sv \
            $(RTL_DIR)/adpll_freq_counter.sv \
            $(RTL_DIR)/loop_filter/adpll_loop_filter_$(FILTER).sv \
            $(RTL_DIR)/adpll_lock_detector.sv \
            $(RTL_DIR)/adpll_post_divider.sv

# ivlng runtime deps: the libvvp build + the nix libs it (and ivlng.vpi) pull in. Located from the store.
NIXLIB = $(shell ls -d /nix/store/*$(1)*/lib 2>/dev/null | grep -v -- -dev | head -1)
IVLNG_LIBS := $(IVL_PREFIX)/lib:$(call NIXLIB,bzip2-1.0.8):$(call NIXLIB,zlib-1.3):$(call NIXLIB,readline-8.3):$(call NIXLIB,gcc-14)

# Per-(config, corner) build dir so independent sims run in parallel without clobbering each other.
B         := build/$(ADPLL)/$(CORNER)
RING      := $(B)/ring.spice
RING_BB   := $(B)/ring_bb.v
SYNTH_V   := $(B)/synth.v
SYNTH_VVP := $(B)/synth.vvp
TB        := $(B)/cosim_tb.spice
LOG       := $(B)/cosim.log

.PHONY: cosim clean
.DELETE_ON_ERROR:

cosim: $(SYNTH_VVP) $(RING)
	@test -e "$(LIBVVP)" || { echo "ERROR: $(LIBVVP) not found -- ivlng needs iverilog built --enable-libvvp. Set IVL_PREFIX=<that install>, or put a libvvp iverilog first on PATH."; exit 1; }
	./generate_cosim_tb.py \
	 --vvp synth.vvp \
	 --ring-subckt $(RINGDCO) \
	 --corner $(CORNER) \
	 --ref-mhz $(REF_MHZ) \
	 --mul $(MUL) \
	 --div $(DIV) \
	 --post-div $(POST_DIV) > $(TB)
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

# Blackbox stub for the ring so read_slang accepts the wrapper's parameterized ring instantiation
$(RING_BB): $(RTL_DIR)/dco/$(RINGDCO).sv
	mkdir -p $(dir $@)
	{ echo '(* blackbox *)'; sed -n '/^module/,/);/p' $<; echo endmodule; } > $@

$(RING): ../librelane/ring_dco.yaml
	mkdir -p $(dir $@)
	librelane ../librelane/ring_dco.yaml --pdk $(PDK) --pdk-root $(PDK_ROOT) --scl $(SCL) -c DESIGN_NAME=$(RINGDCO)
	cp $$(ls -td ../librelane/runs/*/final/spice/$(RINGDCO).spice | head -1) $@

$(SYNTH_V): $(LOOP_RTL) $(RING_BB)
	mkdir -p $(dir $@)
	yosys -m slang \
	 -p "read_slang \
	      --ignore-unknown-modules \
	      -G FreqDetectorMaxEdgesPerWindow=255 \
	      -G FreqDetectorMaxWindowSize=15 \
	      $(RING_BB) \
	      $(LOOP_RTL)" \
	 -p "hierarchy -top $(ADPLL)" \
	 -p "delete t:$(RINGDCO)" \
	 -p "expose -input w:dco_clk" \
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
