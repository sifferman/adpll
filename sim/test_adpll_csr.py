# cocotb unit test for s_axi_adpll_csr -- the ONLY digital block we verify in a logic simulator
# (the detector / filter / lock / DCO are analog and signed off in SPICE: `make adpll-spice`).
#
# Drives the AXI4-Lite slave exactly as the on-chip fabric does, using cocotbext-axi's AxiLiteMaster:
# program MUL / DIV, set CTRL.enable, and check the control outputs; then drive the lock / tune status
# inputs and read STATUS back. No FLL chain, no DCO -- just the register file.
#
#   pip install cocotb cocotbext-axi      # + iverilog on PATH
#   python3 sim/test_adpll_csr.py         # (or: make sim-adpll-csr)

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotbext.axi import AxiLiteBus, AxiLiteMaster

# register byte offsets (see s_axi_adpll_csr.sv)
CTRL, REF_MUL, REF_DIV, STATUS, POST_DIV = 0x0, 0x4, 0x8, 0xC, 0x10
NUM_TUNE = 7


@cocotb.test()
async def csr_program_and_status(dut):
    """Program mul/div/enable over AXI4-Lite, then read lock/tune back through STATUS."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())  # 50 MHz
    axil = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axil"), dut.clk, dut.rst,
                         reset_active_level=True)

    # reset (active-high rst); park the status inputs
    dut.rst.value = 1
    dut.lock.value = 0
    dut.tune.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

    # post_div comes out of reset at 1 (passthrough)
    assert int(await axil.read_dword(POST_DIV)) == 1, "POST_DIV reset value not 1"

    # program the synthesizer ratio + output divide, exactly as a host would over Ethernet
    await axil.write_dword(REF_MUL, 1707)
    await axil.write_dword(REF_DIV, 256)
    await axil.write_dword(POST_DIV, 5)
    assert int(await axil.read_dword(REF_MUL)) == 1707, "REF_MUL readback mismatch"
    assert int(await axil.read_dword(REF_DIV)) == 256, "REF_DIV readback mismatch"
    assert int(await axil.read_dword(POST_DIV)) == 5, "POST_DIV readback mismatch"

    # CTRL.enable -> the enable output (and reads back)
    assert dut.enable.value == 0, "enable asserted before CTRL written"
    await axil.write_dword(CTRL, 1)
    assert int(await axil.read_dword(CTRL)) & 1 == 1, "CTRL.enable not set"
    await ClockCycles(dut.clk, 1)
    assert dut.enable.value == 1, "enable output not driven"
    assert int(dut.ref_mul.value) == 1707, "ref_mul output mismatch"
    assert int(dut.ref_div.value) == 256, "ref_div output mismatch"
    assert int(dut.post_div.value) == 5, "post_div output mismatch"

    # STATUS reflects the lock / tune status inputs: [0] lock, [NumTuneBits:1] tune
    for tune in (0, 42, (1 << NUM_TUNE) - 1):
        dut.lock.value = 1
        dut.tune.value = tune
        await ClockCycles(dut.clk, 2)
        status = int(await axil.read_dword(STATUS))
        assert status & 1 == 1, f"STATUS lock bit low (status={status:#x})"
        assert (status >> 1) & ((1 << NUM_TUNE) - 1) == tune, \
            f"STATUS tune field {(status >> 1) & ((1 << NUM_TUNE) - 1)} != {tune}"

    dut.lock.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(await axil.read_dword(STATUS)) & 1 == 0, "STATUS lock stuck high"
    dut._log.info("PASS: s_axi_adpll_csr program + status readback")


def _run():
    from cocotb_tools.runner import get_runner

    rtl = Path(__file__).resolve().parent.parent / "rtl"
    sim = os.getenv("SIM", "icarus")
    runner = get_runner(sim)
    runner.build(
        sources=[rtl / "axi" / "s_axi_adpll_csr.sv"],
        hdl_toplevel="s_axi_adpll_csr",
        build_args=["-g2012"] if sim == "icarus" else [],
        timescale=("1ns", "1ps"),
        always=True,
    )
    runner.test(hdl_toplevel="s_axi_adpll_csr", test_module="test_adpll_csr",
                timescale=("1ns", "1ps"))


if __name__ == "__main__":
    _run()
