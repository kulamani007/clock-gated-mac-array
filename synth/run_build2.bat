@echo off
REM Build the DSP-friendly (no datapath reset) variant and its ungated control.
REM Appends to the existing summary_area.csv - does not rewrite the header.
setlocal
set VIV=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
set PART=xc7a100tcsg324-1
set PERIOD=4.0
cd /d C:\Users\routk\Downloads\clock_gated_mac_array\synth

REM Stale .Xil scratch dirs from a crashed run make synth_design fail with
REM "couldn't read file .../realtime/<top>.tcl". Always clean before building.
if exist .Xil rd /s /q .Xil

echo ===== BUILD : dsp (zero-skip, DSP-friendly reset) =====
call %VIV% -mode batch -nojournal -log rpt\vivado_dsp.log -source build.tcl -tclargs mac_cascade_zs_dsp_top dsp %PART% %PERIOD%

echo ===== BUILD : dsp0 (same structure, gating DISABLED - control) =====
call %VIV% -mode batch -nojournal -log rpt\vivado_dsp0.log -source build.tcl -tclargs mac_cascade_dsp_nogate_top dsp0 %PART% %PERIOD%

echo.
type rpt\summary_area.csv
echo ===== BUILD2 DONE =====
