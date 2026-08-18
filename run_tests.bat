@echo off
REM ===========================================================================
REM  Reproducible test runner - clock_gated_mac_array
REM  Uses the Icarus Verilog shipped with oss-cad-suite.
REM  NOTE: oss-cad-suite's environment.bat MUST be sourced first - without it
REM  iverilog cannot locate its ivl backend and silently produces no output.
REM  Run from this directory:   run_tests.bat
REM ===========================================================================
setlocal
call "C:\Users\routk\Downloads\oss-cad-suite\environment.bat"

set BASE=rtl\completion_aware_gate.v rtl\pipelined_mac.v rtl\adder_tree_stage.v rtl\mac_array_and_cascade_top.v
set ZS=rtl\zero_skip_gate.v rtl\pipelined_mac_zs.v rtl\adder_tree_stage_zs.v rtl\mac_cascade_zs_top.v

if not exist sim mkdir sim

echo ===== 1. BASELINE REGRESSION (tb_cascade) =====
iverilog -g2012 -s tb_cascade -o sim\base %BASE% rtl\tb_cascade.v
if errorlevel 1 goto :fail
vvp sim\base

echo.
echo ===== 2. ZERO-SKIP EQUIVALENCE + EDGE CASES (tb_zero_skip) =====
iverilog -g2012 -s tb_zero_skip -o sim\zs %BASE% %ZS% tb\tb_zero_skip.v
if errorlevel 1 goto :fail
vvp sim\zs

echo.
echo ===== 3. NEGATIVE CONTROL (tb_negative_control) =====
iverilog -g2012 -s tb_negative_control -o sim\neg %BASE% %ZS% negctl\pipelined_mac_naive.v negctl\tb_negative_control.v
if errorlevel 1 goto :fail
vvp sim\neg

echo.
echo ===== 4. SPARSITY SWEEP (tb_sparsity_sweep) =====
iverilog -g2012 -s tb_sparsity_sweep -o sim\sweep %BASE% %ZS% tb\tb_sparsity_sweep.v
if errorlevel 1 goto :fail
vvp sim\sweep

echo.
echo ===== 5. INPUT-REGISTERED VARIANT (tb_zero_skip_ir) =====
iverilog -g2012 -s tb_zero_skip_ir -o sim\ir %BASE% %ZS% rtl\pipelined_mac_zs_ir.v tb\tb_zero_skip_ir.v
if errorlevel 1 goto :fail
vvp sim\ir

echo.
echo ===== ALL SIMULATIONS COMPLETED =====
goto :eof

:fail
echo.
echo *** COMPILE FAILED ***
exit /b 1
