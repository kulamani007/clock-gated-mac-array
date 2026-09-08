@echo off
REM Fill the two missing baseline RTL-SAIF points (s25, s50) using the
REM corrected flat/config-file flow, and echo the simulated SPARSITY so the
REM label can be confirmed against the data rather than assumed.
setlocal
set VDIR=C:\Xilinx\Vivado\2023.2\bin
set ROOT=C:\Users\routk\Downloads\clock_gated_mac_array
cd /d %ROOT%\synth
set SRC=%ROOT%\rtl\completion_aware_gate.v %ROOT%\rtl\pipelined_mac.v %ROOT%\rtl\adder_tree_stage.v %ROOT%\rtl\mac_array_and_cascade_top.v %ROOT%\rtl\zero_skip_gate.v %ROOT%\rtl\pipelined_mac_zs.v %ROOT%\rtl\adder_tree_stage_zs.v %ROOT%\rtl\mac_cascade_zs_top.v %ROOT%\rtl\pipelined_mac_zs_ir.v %ROOT%\rtl\pipelined_mac_zs_dsp.v

call :one base DUT_BASE 25
call :one base DUT_BASE 50
echo FILL_DONE
goto :eof

:one
setlocal
set TAG=%1
set DEF=%2
set SP=%3
echo ---- %TAG% s%SP% ----
if exist xsim.dir rd /s /q xsim.dir
if exist .Xil rd /s /q .Xil
set CFG=cfgr_%TAG%_%SP%.v
> %CFG% echo `define %DEF%
>> %CFG% echo `define SPARSITY_PCT %SP%
>> %CFG% echo `define RUN_CYC 800
>> %CFG% echo `include "tb_power.v"
call %VDIR%\xvlog.bat %SRC% %CFG% > log_f_xvlog_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XVLOG FAILED & endlocal & goto :eof)
call %VDIR%\xelab.bat tb_power -s fr_%TAG%_%SP% -debug typical -timescale 1ns/1ps > log_f_xelab_%TAG%_%SP%.txt 2>&1
if errorlevel 1 (echo XELAB FAILED & endlocal & goto :eof)
> saif_f.tcl echo open_saif saif/%TAG%_s%SP%.saif
>> saif_f.tcl echo log_saif [get_objects -r /tb_power/dut/*]
>> saif_f.tcl echo run all
>> saif_f.tcl echo close_saif
>> saif_f.tcl echo quit
call %VDIR%\xsim.bat fr_%TAG%_%SP% -tclbatch saif_f.tcl > log_f_xsim_%TAG%_%SP%.txt 2>&1
findstr /C:"tb_power done" log_f_xsim_%TAG%_%SP%.txt
call %VDIR%\vivado.bat -mode batch -nojournal -log log_f_pwr_%TAG%_%SP%.txt -source power.tcl -tclargs %TAG% %TAG%_s%SP%.saif s%SP%
endlocal
goto :eof
