@echo off
REM ===========================================================================
REM  SAIF-driven power characterisation.
REM  For each design and each sparsity level: simulate with xsim, dump SAIF,
REM  then apply that SAIF to the ROUTED checkpoint and run report_power.
REM  All designs see bit-identical stimulus at a given sparsity (same LFSR).
REM
REM  Three things that must be right or this silently produces nothing:
REM    1. defines must be QUOTED   -d "SPARSITY_PCT=25"   (the .bat wrapper
REM       otherwise splits on '=' and reports "Can not find file: 25")
REM    2. xelab needs -timescale   (the RTL declares none, the TB does)
REM    3. the SAIF path in the xsim Tcl must use FORWARD SLASHES - Tcl treats
REM       backslashes as escapes, so a Windows path silently writes nothing
REM ===========================================================================
setlocal enabledelayedexpansion
set VDIR=C:\Xilinx\Vivado\2023.2\bin
set ROOT=C:\Users\routk\Downloads\clock_gated_mac_array
cd /d %ROOT%\synth

if not exist saif mkdir saif
if not exist rpt  mkdir rpt
echo tag,label,total_W,dynamic_W,clocks_W,signals_W,logic_W,dsp_W,confidence > rpt\summary_power.csv

set SRC=%ROOT%\rtl\completion_aware_gate.v %ROOT%\rtl\pipelined_mac.v %ROOT%\rtl\adder_tree_stage.v %ROOT%\rtl\mac_array_and_cascade_top.v %ROOT%\rtl\zero_skip_gate.v %ROOT%\rtl\pipelined_mac_zs.v %ROOT%\rtl\adder_tree_stage_zs.v %ROOT%\rtl\mac_cascade_zs_top.v %ROOT%\rtl\pipelined_mac_zs_ir.v %ROOT%\rtl\pipelined_mac_zs_dsp.v tb_power.v

REM 'ir' is omitted here: its role in the study is the area/timing evidence
REM that an async datapath reset blocks DSP48 packing, and it does not meet
REM timing, so a power number for it would not be meaningful.
REM Loop SPARSITY-MAJOR so that a complete cross-section of all four designs
REM lands early; a design-major order would leave the most important variant
REM (dsp) unmeasured until the very end of a multi-hour sweep.
for %%S in (0 50 90 25 75) do (
  for %%P in (base.DUT_BASE zs.DUT_ZS dsp.DUT_DSP dsp0.DUT_DSP0) do (
    for /f "tokens=1,2 delims=." %%a in ("%%P") do (
      call :dorun %%a %%b %%S
    )
  )
)

echo.
echo ===== POWER SUMMARY =====
type rpt\summary_power.csv
echo ===== POWER STAGE DONE =====
goto :eof

:dorun
set TAG=%1
set DEF=%2
set SP=%3
echo.
echo ---- %TAG% sparsity %SP%%% ----

if exist xsim.dir rd /s /q xsim.dir
if exist .Xil rd /s /q .Xil

REM 800 cycles of steady-state activity is ample for a stable SAIF and keeps
REM the 20-run sweep tractable; 2000 made each run dominated by SAIF logging.
call %VDIR%\xvlog.bat -d %DEF% -d "SPARSITY_PCT=%SP%" -d "RUN_CYC=800" %SRC% > log_xvlog_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XVLOG FAILED %TAG% %SP% & goto :eof)

call %VDIR%\xelab.bat tb_power -s pw_%TAG%_%SP% -debug typical -timescale 1ns/1ps > log_xelab_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XELAB FAILED %TAG% %SP% & goto :eof)

> saif_dump.tcl echo open_saif saif/%TAG%_s%SP%.saif
>> saif_dump.tcl echo log_saif [get_objects -r /tb_power/dut/*]
>> saif_dump.tcl echo run all
>> saif_dump.tcl echo close_saif
>> saif_dump.tcl echo quit

call %VDIR%\xsim.bat pw_%TAG%_%SP% -tclbatch saif_dump.tcl > log_xsim_%TAG%_%SP%.txt 2>&1

if not exist saif\%TAG%_s%SP%.saif (echo NO SAIF PRODUCED for %TAG% %SP% & goto :eof)

call %VDIR%\vivado.bat -mode batch -nojournal -log log_pwr_%TAG%_%SP%.txt -source power.tcl -tclargs %TAG% %TAG%_s%SP%.saif s%SP%
goto :eof
