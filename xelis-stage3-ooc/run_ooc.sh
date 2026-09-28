#!/usr/bin/env bash
# Out-of-context synthesis of the XelisHash v3 stage-3 primitives, in WSL.
#
# Deliberately does NOT reproduce the defects catalogued in
# FPGA Dev/buildscripts/README.md:
#   - set -e and set -o pipefail are on, so a failing tool cannot look like
#     success just because the grep after it printed nothing (entry 2).
#   - the working directory is created and entered with the failure checked,
#     rather than ooc.sh's mkdir-one-directory-and-cd-to-another (entry 65).
#   - no rm -rf of a directory that might hold the only copy of a result.
#
# Usage: run_ooc.sh [target_period_ns]        default 2.500

set -euo pipefail

PERIOD="${1:-2.500}"

V="$HOME/Xilinx-2023.1"
export LOCPATH="$HOME/.locale"
export LD_LIBRARY_PATH="$HOME/lib:${LD_LIBRARY_PATH:-}"
# Quote it. Under WSL the Windows PATH is inherited and contains "(x86)" and
# spaces, which breaks an unquoted expansion.
export PATH="$HOME/bin:$PATH"
# shellcheck disable=SC1090
source "$V/Vivado/2023.1/settings64.sh" > /dev/null
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/fpga/xelis-ooc"

mkdir -p "$DST/rtl" "$DST/tcl"
cd "$DST" || { echo "FATAL: cannot enter $DST"; exit 1; }

# Stage the sources. Vivado on a 9p mount with spaces in the path is a fight
# not worth having, so copy into the WSL filesystem and build there.
cp -f "$SRC/rtl/"*.sv  "$DST/rtl/"
cp -f "$SRC/tcl/"*.tcl "$DST/tcl/"
echo "staged: $(ls -1 "$DST/rtl" | wc -l) rtl, $(ls -1 "$DST/tcl" | wc -l) tcl"
sha256sum "$DST"/rtl/*.sv

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DST/ooc-$STAMP.log"

echo "=== synth, target period ${PERIOD} ns ==="
set +e
vivado -mode batch -nojournal -nolog -notrace \
       -source "$DST/tcl/ooc_synth.tcl" -tclargs "$PERIOD" "$DST/rtl" \
       > "$LOG" 2>&1
VRC=$?
set -e
echo "VIVADO_RC=$VRC"

# Print the results whether or not Vivado returned 0: a per-top failure is
# reported as RESULT_ERROR and the other tops still carry information.
grep -aE "OOC_RUN|OOC_TOP|RESULT_" "$LOG" || echo "(no RESULT lines -- see $LOG)"
echo "log: $LOG"
exit "$VRC"
