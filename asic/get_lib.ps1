$dir = "C:\Users\routk\Downloads\clock_gated_mac_array\asic\lib"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$dst = Join-Path $dir "sky130_fd_sc_hd__tt_025C_1v80.lib"
if (Test-Path $dst) {
  Write-Output ("already present: {0:N1} MB" -f ((Get-Item $dst).Length/1MB))
} else {
  $u = "https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
  Write-Output "downloading sky130_fd_sc_hd typical corner ..."
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $u -OutFile $dst -TimeoutSec 600 -UseBasicParsing
  Write-Output ("downloaded: {0:N1} MB" -f ((Get-Item $dst).Length/1MB))
}
Write-Output "---- is OpenSTA available? ----"
$sta = Get-ChildItem -Path "C:\Users\routk\Downloads\oss-cad-suite\bin" -Filter "sta*.exe" -ErrorAction SilentlyContinue
if ($sta) { $sta | ForEach-Object { Write-Output $_.FullName } } else { Write-Output "no OpenSTA in oss-cad-suite" }
