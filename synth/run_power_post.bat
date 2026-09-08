@echo off
REM ===========================================================================
REM  POST-IMPLEMENTATION SAIF power characterisation.
REM
REM  Why not RTL SAIF: applying an RTL-simulation SAIF to a routed checkpoint
REM  matched only 13-21%% of design nets, so most activity was vectorless
REM  estimation. It is also systematically biased against the DSP-packed
REM  variant, whose operand registers are absorbed into the DSP48 and so have
REM  no corresponding RTL net to annotate. This flow simulates the routed
REM  netlist itself.
REM
REM  Two cmd hazards this file deliberately avoids:
REM   * nested FOR + CALL mis-scopes the loop variables, which silently ran
REM     every case at sparsity 0 while labelling it otherwise. The call list
REM     below is therefore FLAT and explicit.
REM   * multiple -d options through the xvlog .bat wrapper are unreliable, so
REM     the defines are written into a generated config file that `include`s
REM     the testbench instead.
REM ===========================================================================
setlocal
set VDIR=C:\Xilinx\Vivado\2023.2\bin
set ROOT=C:\Users\routk\Downloads\clock_gated_mac_array
set GLBL=C:\Xilinx\Vivado\2023.2\data\verilog\src\glbl.v
cd /d %ROOT%\synth

if not exist saifp mkdir saifp
if not exist rpt   mkdir rpt
echo tag,label,total_W,dynamic_W,clocks_W,signals_W,logic_W,dsp_W,confidence > rpt\summary_power_post.csv

echo ===== generating post-implementation netlists =====
for %%T in (base zs dsp dsp0) do (
  if not exist netlist\%%T_funcsim.v (
    if exist .Xil rd /s /q .Xil
    call %VDIR%\vivado.bat -mode batch -nojournal -log log_net_%%T.txt -source gen_netlist.tcl -tclargs %%T
  )
)

call :dorun base DUT_BASE 0
call :dorun zs   DUT_ZS   0
call :dorun dsp  DUT_DSP  0
call :dorun dsp0 DUT_DSP0 0

call :dorun base DUT_BASE 50
call :dorun zs   DUT_ZS   50
call :dorun dsp  DUT_DSP  50
call :dorun dsp0 DUT_DSP0 50

call :dorun base DUT_BASE 90
call :dorun zs   DUT_ZS   90
call :dorun dsp  DUT_DSP  90
call :dorun dsp0 DUT_DSP0 90

echo.
echo ===== POST-IMPL POWER SUMMARY =====
type rpt\summary_power_post.csv
echo ===== DONE =====
goto :eof

REM ---------------------------------------------------------------------------
:dorun
setlocal
set TAG=%1
set DEF=%2
set SP=%3
echo.
echo ---- POST %TAG% sparsity %SP% ----

if exist xsim.dir rd /s /q xsim.dir
if exist .Xil rd /s /q .Xil

set CFG=cfg_%TAG%_%SP%.v
> %CFG% echo `define NETLIST_SIM
>> %CFG% echo `define %DEF%
>> %CFG% echo `define SPARSITY_PCT %SP%
>> %CFG% echo `define RUN_CYC 800
>> %CFG% echo `include "tb_power.v"

call %VDIR%\xvlog.bat netlist\%TAG%_funcsim.v %GLBL% %CFG% > log_pxvlog_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XVLOG FAILED %TAG% %SP% & endlocal & goto :eof)

call %VDIR%\xelab.bat tb_power glbl -s pp_%TAG%_%SP% -debug typical -timescale 1ns/1ps -L unisims_ver -L simprims_ver -L secureip > log_pxelab_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XELAB FAILED %TAG% %SP% & endlocal & goto :eof)

> saif_post.tcl echo open_saif saifp/%TAG%_s%SP%.saif
>> saif_post.tcl echo log_saif [get_objects -r /tb_power/dut/*]
>> saif_post.tcl echo run all
>> saif_post.tcl echo close_saif
>> saif_post.tcl echo quit

call %VDIR%\xsim.bat pp_%TAG%_%SP% -tclbatch saif_post.tcl > log_pxsim_%TAG%_%SP%.txt 2>&1
findstr /C:"tb_power done" log_pxsim_%TAG%_%SP%.txt

if not exist saifp\%TAG%_s%SP%.saif (echo NO SAIF for %TAG% %SP% & endlocal & goto :eof)

call %VDIR%\vivado.bat -mode batch -nojournal -log log_ppwr_%TAG%_%SP%.txt -source power_post.tcl -tclargs %TAG% %TAG%_s%SP%.saif s%SP%
endlocal
goto :eof
