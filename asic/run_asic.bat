@echo off
REM ===========================================================================
REM  Standard-cell synthesis with Yosys + ABC against the open SkyWater
REM  sky130_fd_sc_hd library (typical corner, 25 C, 1.8 V).
REM
REM  PURPOSE. The FPGA results are entangled with the DSP48 hard macro: the
REM  reset style decides whether the operand registers pack into the slice,
REM  which in turn decides whether the multiplier can be quieted at all. On an
REM  ASIC there is no hard macro - the multiplier is ordinary gates - so this
REM  flow answers two questions the FPGA flow cannot:
REM    1. What does the gating actually cost in standard cells?
REM    2. Is the reset-style dependency an FPGA artefact, as predicted?
REM
REM  No OpenSTA is available here, so timing is ABC's estimate only and is
REM  reported as such. Area and cell counts are the trustworthy outputs.
REM ===========================================================================
setlocal
set ROOT=C:\Users\routk\Downloads\clock_gated_mac_array
set LIB=%ROOT%/asic/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
cd /d %ROOT%\asic

call C:\Users\routk\Downloads\oss-cad-suite\environment.bat >nul 2>&1
if not exist rpt mkdir rpt
if not exist netlist mkdir netlist

call :one mac_cascade_top            base
call :one mac_cascade_zs_top         zs
call :one mac_cascade_zs_ir_top      ir
call :one mac_cascade_zs_dsp_top     dsp
call :one mac_cascade_dsp_nogate_top dsp0

echo.
echo ===== ASIC AREA SUMMARY =====
findstr /C:"Chip area" rpt\*.log
echo ===== ASIC DONE =====
goto :eof

:one
setlocal
set TOP=%1
set TAG=%2
echo ---- yosys %TAG% (%TOP%) ----
set YS=%TAG%.ys
> %YS% echo read_verilog %ROOT%/rtl/completion_aware_gate.v %ROOT%/rtl/pipelined_mac.v %ROOT%/rtl/adder_tree_stage.v %ROOT%/rtl/mac_array_and_cascade_top.v %ROOT%/rtl/zero_skip_gate.v %ROOT%/rtl/pipelined_mac_zs.v %ROOT%/rtl/adder_tree_stage_zs.v %ROOT%/rtl/mac_cascade_zs_top.v %ROOT%/rtl/pipelined_mac_zs_ir.v %ROOT%/rtl/pipelined_mac_zs_dsp.v
>> %YS% echo hierarchy -check -top %TOP%
>> %YS% echo synth -top %TOP% -flatten
>> %YS% echo dfflibmap -liberty %LIB%
>> %YS% echo abc -liberty %LIB% -D 3000
>> %YS% echo setundef -zero
>> %YS% echo opt_clean -purge
>> %YS% echo stat -liberty %LIB%
>> %YS% echo write_verilog -noattr %ROOT%/asic/netlist/%TAG%_sky130.v

yosys -q -l rpt\%TAG%.log %YS%
if errorlevel 1 echo YOSYS FAILED %TAG%
endlocal
goto :eof
