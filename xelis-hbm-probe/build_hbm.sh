#!/usr/bin/env bash
# Build the HBM probe. Vivado/Vitis 2023.1 ONLY -- 2025.1 cannot decrypt this
# platform's clk_metadata_adapter IP.
#
# Follows build2023_280.sh: assert what actually got built BEFORE starting the
# link, because the link is the expensive step and a wrong .xo looks completely
# normal until hours later.
#
# Does NOT rm -rf the build directory. build2023.sh opens with one and it has
# already destroyed two completed runs' reports.

set -uo pipefail

V="$HOME/Xilinx-2023.1"
export LOCPATH="$HOME/.locale"
export LD_LIBRARY_PATH="$HOME/lib:${LD_LIBRARY_PATH:-}"
export PATH="$HOME/bin:$PATH"
# shellcheck disable=SC1090
source "$V/Vivado/2023.1/settings64.sh" > /dev/null
# shellcheck disable=SC1090
source "$V/Vitis/2023.1/settings64.sh" > /dev/null
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HOME/fpga/hbm_probe"
PFM="$HOME/opt/platforms/xilinx_u55n_gen3x4_xdma_2_202110_1/xilinx_u55n_gen3x4_xdma_2_202110_1.xpfm"

mkdir -p "$B/src"
cd "$B" || { echo "FATAL: cannot enter $B"; exit 1; }

cp -f "$SRC/src/hbm_probe.cpp" "$B/src/"
cp -f "$SRC/hbm_probe.cfg"     "$B/"
echo "staged:"
sha256sum "$B/src/hbm_probe.cpp" "$B/hbm_probe.cfg"

echo "=== COMPILE (HLS -> .xo) ==="
v++ -c -t hw --platform "$PFM" -k hbm_probe \
    --temp_dir "$B/ct" --log_dir "$B/cl" --report_dir "$B/cr" \
    -o "$B/hbm_probe.xo" "$B/src/hbm_probe.cpp" > "$B/compile.log" 2>&1
CRC=$?
echo "COMPILE_RC=$CRC"
grep -aE "^ERROR|Compilation failed|II Violation|Estimated Fmax" "$B/compile.log" | head -20

# Refuse to start the link unless the .xo is real. An empty or missing .xo after
# a "successful" compile is exactly the silent failure this guard exists for.
if [ ! -f "$B/hbm_probe.xo" ]; then
    echo "ABORT: no hbm_probe.xo was produced"; exit 1
fi
XO_SZ=$(stat -c %s "$B/hbm_probe.xo")
echo "xo_bytes=$XO_SZ"
if [ "$XO_SZ" -lt 100000 ]; then
    echo "ABORT: hbm_probe.xo is only $XO_SZ bytes, that is not a real kernel"; exit 1
fi
if [ "$CRC" -ne 0 ]; then
    echo "ABORT: compile returned $CRC"; exit 1
fi

# Assert the clock the cfg asks for, so a silently-defaulted 300 MHz cannot be
# mistaken for a deliberate one later.
WANT_HZ=$(grep -aoE "freqHz=[0-9]+" "$B/hbm_probe.cfg" | head -1 | cut -d= -f2)
echo "cfg_requests_freqHz=${WANT_HZ:-NONE}"
if [ -z "${WANT_HZ:-}" ]; then
    echo "ABORT: cfg does not pin the kernel clock"; exit 1
fi

# Refuse to start a multi-hour link for a clock the kernel cannot make. HLS
# prints its own estimate; if that is below the pinned target the link cannot
# close and v++ writes no bitstream at all. This guard turns a two-hour failure
# into a two-minute one, and it is the concrete form of the rule that every
# target should come from a measurement rather than a guess.
FMAX=$(grep -aoE "Estimated Fmax: [0-9.]+" "$B/compile.log" | tail -1 | grep -oE "[0-9.]+")
echo "hls_estimated_fmax_mhz=${FMAX:-UNKNOWN}"
if [ -z "${FMAX:-}" ]; then
    echo "WARNING: no HLS Fmax estimate found; proceeding without the guard"
else
    WANT_MHZ=$(awk -v hz="$WANT_HZ" 'BEGIN{printf "%.2f", hz/1000000}')
    if awk -v f="$FMAX" -v w="$WANT_MHZ" 'BEGIN{exit !(f < w)}'; then
        echo "ABORT: HLS estimates ${FMAX} MHz but the cfg pins ${WANT_MHZ} MHz."
        echo "       The link would fail timing and write no bitstream."
        echo "       Lower freqHz in hbm_probe.cfg, or shorten the kernel's"
        echo "       critical path, then rebuild."
        exit 1
    fi
    echo "guard ok: HLS ${FMAX} MHz >= target ${WANT_MHZ} MHz"
fi

echo "=== LINK (this is the multi-hour step) ==="
v++ --link -t hw --platform "$PFM" \
    --vivado.synth.jobs 4 --vivado.impl.jobs 4 \
    --config "$B/hbm_probe.cfg" \
    --temp_dir "$B/t" --report_dir "$B/r" --log_dir "$B/l" \
    -o "$B/hbm_probe.xclbin" "$B/hbm_probe.xo" > "$B/link.log" 2>&1
LRC=$?
echo "LINK_RC=$LRC"
grep -aE "cfgen receives -clock|system_link: |Step vpl|Run Status|8-5809|^ERROR" "$B/link.log" | head -15

if [ -f "$B/hbm_probe.xclbin" ]; then
    ls -l "$B/hbm_probe.xclbin"
    echo "BUILD_OK"
else
    echo "(no xclbin produced)"
    echo "--- timing, if the link got that far:"
    grep -aE "WNS|Timing constraints are not met|clk_out1" "$B/link.log" | tail -10
    echo "BUILD_FAILED"
fi
exit "$LRC"
