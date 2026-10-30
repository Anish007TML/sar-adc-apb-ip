# =============================================================================
#  SAR ADC APB IP - build / verification flow
#  Tools: Icarus Verilog, Yosys, Verilator (lint), Python3 + numpy + matplotlib
# =============================================================================
RTL      := rtl/sar_ctrl.v rtl/adc_apb_regs.v rtl/sar_adc_ip.v
TB       := tb/analog_frontend_model.v tb/tb_sar_adc.v
BUILD    := build
SIM      := $(BUILD)/sim.vvp
GLS      := $(BUILD)/gls.vvp
NETLIST  := $(BUILD)/sar_adc_ip_netlist.v

# "realistic" analog non-idealities for the behavioral model
MISMATCH := +MISMATCH_PPM=5000 +SEED=7
REAL     := $(MISMATCH) +NOISE_UV=900 +OFFSET_UV=2000 +KTC_UV=200

.PHONY: all lint test sweeps analyze synth gls wave clean help

all: lint test synth gls analyze        ## full flow

help:
	@grep -E '^[a-z]+:.*##' Makefile | sed 's/:.*##/ -/'

$(BUILD):
	@mkdir -p $(BUILD)

$(SIM): $(RTL) $(TB) | $(BUILD)
	iverilog -g2005 -Wall -o $@ $(RTL) $(TB)

lint:                                    ## Verilator lint (-Wall) on the RTL
	verilator --lint-only -Wall $(RTL) --top-module sar_adc_ip
	@echo "LINT: clean"

test: $(SIM)                             ## self-checking functional regression
	vvp -n $(SIM) | tee $(BUILD)/regress.log
	@grep -q "RESULT: PASS" $(BUILD)/regress.log

wave: $(SIM)                             ## regression with VCD dump (open in GTKWave)
	vvp -n $(SIM) +VCD
	@echo "waveform: $(BUILD)/tb_sar_adc.vcd"

sweeps: $(SIM)                           ## ramp + sine data for INL/DNL and FFT
	vvp -n $(SIM) +TEST=ramp +TAG=ideal
	vvp -n $(SIM) +TEST=sine +TAG=ideal
	vvp -n $(SIM) +TEST=ramp +TAG=mismatch $(MISMATCH)
	vvp -n $(SIM) +TEST=ramp +TAG=real $(REAL)
	vvp -n $(SIM) +TEST=sine +TAG=real $(REAL)
	vvp -n $(SIM) +TEST=sine +TAG=real_avg8 +AVG=3 $(REAL)
	vvp -n $(SIM) +TEST=trace

analyze: sweeps                          ## INL/DNL/SNDR/ENOB + plots in docs/images
	python3 scripts/analyze_adc.py
	python3 scripts/plot_conversion.py

synth: | $(BUILD)                        ## Yosys logic synthesis + cell statistics
	yosys -q -s syn/synth.ys
	@cat $(BUILD)/synth_stat.txt

gls: synth                               ## gate-level sim of the synthesized netlist
	iverilog -g2005 -DGLS -o $(GLS) $(NETLIST) $(TB)
	vvp -n $(GLS) | tee $(BUILD)/gls.log
	@grep -q "RESULT: PASS" $(BUILD)/gls.log

clean:
	rm -rf $(BUILD)
