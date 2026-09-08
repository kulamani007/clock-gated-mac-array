@echo off
REM Build all three cascades out-of-context and collect area/timing/DSP data.
setlocal
set VIV=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
set PART=xc7a100tcsg324-1
set PERIOD=4.0
cd /d C:\Users\routk\Downloads\clock_gated_mac_array\synth

if not exist rpt mkdir rpt
echo tag,top,part,period_ns,LUT,FF,DSP,CARRY,BUFG,BUFGCE,WNS_ns,Fmax_MHz > rpt\summary_area.csv

echo ===== BUILD 1/3 : baseline =====
call %VIV% -mode batch -nojournal -log rpt\vivado_base.log -source build.tcl -tclargs mac_cascade_top base %PART% %PERIOD%

echo ===== BUILD 2/3 : zero-skip =====
call %VIV% -mode batch -nojournal -log rpt\vivado_zs.log -source build.tcl -tclargs mac_cascade_zs_top zs %PART% %PERIOD%

echo ===== BUILD 3/3 : zero-skip input-registered =====
call %VIV% -mode batch -nojournal -log rpt\vivado_ir.log -source build.tcl -tclargs mac_cascade_zs_ir_top ir %PART% %PERIOD%

echo.
echo ===== AREA / TIMING SUMMARY =====
type rpt\summary_area.csv
echo ===== BUILD STAGE DONE =====
