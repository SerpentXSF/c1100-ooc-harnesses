#!/usr/bin/env bash
# OOC synthesis of the Poseidon2/Goldilocks primitives, in WSL.
# Every command on one line: line continuations get mangled between the
# orchestration layers and bash here.
set -uo pipefail

PERIOD="${1:-2.500}"

V="$HOME/Xilinx-2023.1"
export LOCPATH="$HOME/.locale"
export LD_LIBRARY_PATH="$HOME/lib:${LD_LIBRARY_PATH:-}"
export PATH="$HOME/bin:$PATH"
source "$V/Vivado/2023.1/settings64.sh" > /dev/null
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/fpga/quantus-ooc"

mkdir -p "$DST/rtl" "$DST/tcl"
cd "$DST" || { echo "FATAL: cannot enter $DST"; exit 1; }
cp -f "$SRC/rtl/"*.sv  "$DST/rtl/"
cp -f "$SRC/tcl/"*.tcl "$DST/tcl/"
echo "staged: $(ls -1 "$DST/rtl" | wc -l) rtl files"
sha256sum "$DST"/rtl/*.sv

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DST/ooc-$STAMP.log"
echo "=== synth, target period ${PERIOD} ns ==="
vivado -mode batch -nojournal -nolog -notrace -source "$DST/tcl/ooc_synth.tcl" -tclargs "$PERIOD" "$DST/rtl" > "$LOG" 2>&1
VRC=$?
echo "VIVADO_RC=$VRC"
grep -aE "OOC_RUN|RESULT_" "$LOG" || echo "(no RESULT lines -- see $LOG)"
echo "log: $LOG"
