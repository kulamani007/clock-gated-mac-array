@echo off
setlocal
set VIV=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
cd /d C:\Users\routk\Downloads\clock_gated_mac_array\synth
if exist .Xil rd /s /q .Xil
call %VIV% -mode batch -nojournal -log rpt\vivado_dsp0.log -source build.tcl -tclargs mac_cascade_dsp_nogate_top dsp0 xc7a100tcsg324-1 4.0
type rpt\summary_area.csv
echo RETRY_DONE
