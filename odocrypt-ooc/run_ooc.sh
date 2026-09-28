#!/usr/bin/env bash
# OOC synthesis of one Odocrypt round. Every command on one line.
set -uo pipefail
PERIOD="${1:-2.500}"
V="$HOME/Xilinx-2023.1"
export LOCPATH="$HOME/.locale"
export LD_LIBRARY_PATH="$HOME/lib:${LD_LIBRARY_PATH:-}"
export PATH="$HOME/bin:$PATH"
source "$V/Vivado/2023.1/settings64.sh" > /dev/null
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/fpga/odocrypt-ooc"
mkdir -p "$DST/rtl" "$DST/tcl"
cd "$DST" || { echo "FATAL: cannot enter $DST"; exit 1; }
cp -f "$SRC/rtl/"*.sv "$SRC/rtl/"*.svh "$DST/rtl/" 2>/dev/null
cp -f "$SRC/tcl/"*.tcl "$DST/tcl/"
echo "staged: $(ls -1 "$DST/rtl" | wc -l) rtl files"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DST/ooc-$STAMP.log"
vivado -mode batch -nojournal -nolog -notrace -source "$DST/tcl/ooc_synth.tcl" -tclargs "$PERIOD" "$DST/rtl" > "$LOG" 2>&1
echo "VIVADO_RC=$?"
grep -aE "OOC_RUN|RESULT_|UTIL" "$LOG" || echo "(no results -- see $LOG)"
echo "log: $LOG"
