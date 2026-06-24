# Gate-level mixed-signal co-simulation of one adpll config:
#   analog ring DCO (ngspice, extracted transistors) + the synthesized gf180 GATE loop run in Icarus
#   Verilog, coupled into a closed loop through ngspice's d_cosim XSPICE model via the `ivlng` shim.
#
# The loop netlist is DERIVED from the adpll wrapper by yosys -- there is NO hand-written loop top:
# the ring DCO is black-boxed, its clk_o is promoted to a top input (`dco_clk`), tune stays as
# `debug_dco_tune_o`, and the loop (detector/filter/lock/post-divider) is mapped to gf180 cells.
# Each artifact below is a file target so `make` rebuilds only what changed; everything lands in build/.
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

IVL_PREFIX ?= /tmp/iverilog-libvvp
IVERILOG   := $(IVL_PREFIX)/bin/iverilog

B     := build
RTL   := ../rtl
LIB   := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/lib/$(SCL)__tt_025C_3v30.lib
CELLV := $(PDK_ROOT)/$(PDK)/libs.ref/$(SCL)/verilog/$(SCL).v

# adpll_<filter>_<dco>: split on '_'. The loop-filter file name differs for the linear filter (pi).
FILTER := $(word 2,$(subst _, ,$(ADPLL)))
DCONAME := $(word 3,$(subst _, ,$(ADPLL)))
RINGDCO := ring_dco_$(DCONAME)
FF      := $(FILTER)
ifeq ($(FILTER),linear)
  FF := pi
endif

LOOP_RTL := $(RTL)/adpll/$(ADPLL).sv $(RTL)/adpll_freq_detector.sv $(RTL)/adpll_freq_counter.sv \
            $(RTL)/loop_filter/adpll_loop_filter_$(FF).sv $(RTL)/adpll_lock_detector.sv \
            $(RTL)/adpll_post_divider.sv

# ivlng runtime deps: the libvvp build + the nix libs it (and ivlng.vpi) pull in. Located from the store.
NIXLIB = $(shell ls -d /nix/store/*$(1)*/lib 2>/dev/null | grep -v -- -dev | head -1)
IVLNG_LIBS := $(IVL_PREFIX)/lib:$(call NIXLIB,bzip2-1.0.8):$(call NIXLIB,zlib-1.3):$(call NIXLIB,readline-8.3):$(call NIXLIB,gcc-14)

GL_V   := $(B)/$(ADPLL)_gl.v
GL_VVP := $(B)/$(ADPLL)_gl
DECK   := $(B)/$(ADPLL)_$(CORNER)_ivlng.spice
LOG    := $(B)/$(ADPLL)_$(CORNER).log

.PHONY: cosim clean
.DELETE_ON_ERROR:

cosim: $(DECK) $(GL_VVP) $(B)/ring.spice ## Run the gate-level cosim to lock (ADPLL=, CORNER=)
	@echo "== ngspice gate-level cosim ($(ADPLL) @ $(CORNER)) =="
	cd $(B) && env -u DISPLAY PDK_ROOT=$(PDK_ROOT) \
	  LD_LIBRARY_PATH="$$LD_LIBRARY_PATH:$(IVLNG_LIBS)" PATH="$(IVL_PREFIX)/bin:$$PATH" \
	  ngspice -b $(notdir $(DECK)) 2>&1 | tee $(notdir $(LOG)) | grep -aiE "t_lock|error|aborted" || true
	@t=$$(grep -aoE "t_lock *= *[0-9.eE+-]+" $(LOG) | head -1); \
	  if [ -n "$$t" ]; then echo "$(ADPLL) @ $(CORNER): LOCKED ($$t)"; \
	  else echo "$(ADPLL) @ $(CORNER): NO-LOCK"; exit 1; fi

$(B):
	mkdir -p $(B)

# Blackbox stub for the ring so read_slang accepts the wrapper's parameterized ring instantiation
# (--ignore-unknown-modules alone rejects parameter overrides on an unknown module). Generated, not
# source. Module name is the config's ring; NumFineBits is declared too (harmless for the rings that
# don't use it) so the coarse/fine wrapper's override is accepted.
$(B)/ring_bb.v: | $(B)
	printf '(* blackbox *)\nmodule $(RINGDCO) #(\n  parameter int unsigned NumTuneBits = 7,\n  parameter int unsigned NumFineBits = 3,\n  parameter string Target = "behavioral"\n) (\n  input  wire                   enable_i,\n  input  wire [NumTuneBits-1:0] tune_i,\n  output wire                   clk_o\n);\nendmodule\n' > $@

# Hardened + Magic-extracted ring DCO (transistor netlist with parasitics). Heavy: runs LibreLane.
$(B)/ring.spice: ../librelane/ring_dco.yaml | $(B)
	librelane ../librelane/ring_dco.yaml --pdk $(PDK) --pdk-root $(PDK_ROOT) --scl $(SCL) -c DESIGN_NAME=$(RINGDCO)
	cp $$(ls -td ../librelane/runs/*/final/spice/$(RINGDCO).spice | head -1) $@

# Derive the gate-level loop from the wrapper: black-box the ring, expose dco_clk as a top input, map
# the loop to gf180 cells, write the netlist. The shrunk -G counters keep the loop small enough to lock
# in tens of windows within a tractable transient.
$(GL_V): $(LOOP_RTL) $(B)/ring_bb.v | $(B)
	yosys -m slang -p "read_slang --ignore-unknown-modules -G FreqDetectorMaxEdgesPerWindow=255 -G FreqDetectorMaxWindowSize=15 $(B)/ring_bb.v $(LOOP_RTL); hierarchy -top $(ADPLL); delete t:$(RINGDCO); expose -input w:dco_clk; synth -top $(ADPLL) -flatten; dfflibmap -liberty $(LIB); abc -liberty $(LIB); opt_clean -purge; write_verilog -noattr $@"

# Compile the gate loop + gf180 behavioural cell models into a vvp (timescale stub so vvp time != 1 s).
$(GL_VVP): $(GL_V) $(CELLV) | $(B)
	printf '`timescale 1ns/1ps\n' > $(B)/timescale.v
	$(IVERILOG) -g2012 -o $@ $(B)/timescale.v $(GL_V) $(CELLV)

# Generate the ngspice deck: ties mul/div/post_div, wires the bridges + ring, MSB-first d_cosim vectors.
# Run from build/ so the paths the generator reads (ring.spice, the netlist) and the .include it emits
# all resolve relative to build/, where ngspice itself runs.
$(DECK): gen_ivlng_deck.py $(GL_V) $(B)/ring.spice
	cd $(B) && ../gen_ivlng_deck.py --netlist $(notdir $(GL_V)) --module $(ADPLL) --vvp $(notdir $(GL_VVP)) \
	  --ring ring.spice --ring-subckt $(RINGDCO) --corner $(CORNER) \
	  --ref-mhz $(REF_MHZ) --mul $(MUL) --div $(DIV) --post-div $(POST_DIV) > $(notdir $(DECK))

clean: ## Remove all build artifacts
	rm -rf $(B)
