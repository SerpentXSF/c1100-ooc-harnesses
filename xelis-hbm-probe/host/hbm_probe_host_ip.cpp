// SPDX-License-Identifier: MIT
//
// Register-driven host for the HBM probe.
//
// WHY THIS EXISTS
// ---------------
// The obvious host (hbm_probe_host.cpp) drives the kernel with xrt::run. On
// this card that dies with SIGBUS inside xrt::run_impl::run_impl -- XRT's own
// ERT command-buffer allocation -- before a single argument is set. It works
// fine in software emulation, so the host and kernel logic are correct; the
// hardware managed-execution path is not.
//
// blake2b_host.cpp has always driven its kernel through xrt::ip register reads
// and writes and never calls xrt::run, which is why the project never hit this.
// That path is proven on this hardware, so this host uses it too.
//
// xrt::ip's documented requirements are only that the IP appears in IP_LAYOUT,
// has a base address and an address range, and is opened exclusively -- there is
// no control-protocol requirement, so a standard Vitis HLS s_axilite kernel
// qualifies and needs no rebuild.
//
// REGISTER MAP
// ------------
// Control is the standard HLS ap_ctrl_hs block at 0x00. The argument offsets
// below were read from the xclbin's own EMBEDDED_METADATA rather than assumed:
// note the pointer stride is 12 bytes (8 of address plus 4 of padding), not 8,
// which is exactly the kind of thing that is wrong when guessed.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <tuple>
#include <vector>

#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "experimental/xrt_ip.h"

namespace {

// ap_ctrl_hs control block.
constexpr uint32_t R_CTRL = 0x00;   // bit0 ap_start, bit1 ap_done, bit2 ap_idle
constexpr uint32_t CTRL_START = 0x1;
constexpr uint32_t CTRL_DONE  = 0x2;
constexpr uint32_t CTRL_IDLE  = 0x4;

// From EMBEDDED_METADATA of hbm_probe.xclbin.
constexpr uint32_t A_M0     = 0x10;
constexpr uint32_t A_M1     = 0x1C;
constexpr uint32_t A_M2     = 0x28;
constexpr uint32_t A_M3     = 0x34;
constexpr uint32_t A_MODE   = 0x40;
constexpr uint32_t A_CHAINS = 0x48;
constexpr uint32_t A_ITERS  = 0x50;
constexpr uint32_t A_WORDS  = 0x58;
constexpr uint32_t A_OUT    = 0x64;

uint64_t g_words_per_port = 1ULL << 23;   // 64 MiB
uint64_t g_bytes_per_port = (1ULL << 23) * sizeof(uint64_t);
bool     g_quick = false;

double now_s() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

}  // namespace

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <xclbin> [device_index]\n", argv[0]);
        return 2;
    }
    const std::string xclbin = argv[1];
    const unsigned dev_index = (argc > 2) ? std::strtoul(argv[2], nullptr, 10) : 0;

    if (const char *e = std::getenv("XELIS_WORDS_LOG2")) {
        unsigned lg = std::strtoul(e, nullptr, 10);
        if (lg < 10 || lg > 28) { std::fprintf(stderr, "XELIS_WORDS_LOG2 10..28\n"); return 2; }
        g_words_per_port = 1ULL << lg;
        g_bytes_per_port = g_words_per_port * sizeof(uint64_t);
    }
    g_quick = (std::getenv("XELIS_QUICK") != nullptr);

    try {
        auto device = xrt::device(dev_index);
        auto uuid = device.load_xclbin(xclbin);
        std::printf("xclbin loaded: %s\n", xclbin.c_str());
        std::printf("words/port=%llu (%llu MiB) quick=%d\n",
                    (unsigned long long)g_words_per_port,
                    (unsigned long long)(g_bytes_per_port >> 20), (int)g_quick);

        // Memory groups come from xrt::kernel, which constructs fine -- only
        // xrt::run is broken. Take the metadata, then let it go so the CU is
        // free for xrt::ip's exclusive open.
        std::vector<int> grp;
        {
            auto k = xrt::kernel(device, uuid, "hbm_probe");
            for (int i = 0; i < 9; i++) grp.push_back(k.group_id(i));
        }
        std::printf("memory groups: m0..m3 = %d %d %d %d, out = %d\n",
                    grp[0], grp[1], grp[2], grp[3], grp[8]);


        std::vector<xrt::bo> bo;
        for (int i = 0; i < 4; i++) {
            std::printf("allocating port %d: %llu MiB in group %d ... ", i,
                        (unsigned long long)(g_bytes_per_port >> 20), grp[i]);
            bo.emplace_back(device, g_bytes_per_port, grp[i]);
            std::printf("ok\n");
        }
        auto bo_out = xrt::bo(device, 4096, grp[8]);
        std::printf("result buffer allocated in group %d\n", grp[8]);

        std::printf("filling %llu MiB with random data ...\n",
                    (unsigned long long)((g_bytes_per_port * 4) >> 20));
        {
            std::mt19937_64 rng(0xC1100);
            std::vector<uint64_t> chunk(1ULL << 17);
            for (int i = 0; i < 4; i++) {
                auto *map = bo[i].map<uint64_t *>();
                for (uint64_t off = 0; off < g_words_per_port; off += chunk.size()) {
                    const uint64_t n = std::min<uint64_t>(chunk.size(), g_words_per_port - off);
                    for (uint64_t w = 0; w < n; w++) chunk[w] = rng();
                    std::memcpy(map + off, chunk.data(), n * sizeof(uint64_t));
                }
                bo[i].sync(XCL_BO_SYNC_BO_TO_DEVICE);
            }
        }
        std::printf("buffers ready\n");

        // Buffers are allocated ABOVE, before the IP is opened. The first
        // hardware run did the opposite and the 64 MiB allocation failed with
        // std::bad_alloc, having succeeded minutes earlier under the xrt::run
        // host. Taking the compute unit exclusively appears to break later BO
        // allocation, so the order matters. See mistakes entry 79.
        xrt::ip ip;
        for (const char *nm : {"hbm_probe_1", "hbm_probe"}) {
            try {
                ip = xrt::ip(device, uuid, nm);
                std::printf("opened IP as %s (exclusive)\n", nm);
                break;
            } catch (const std::exception &e) {
                std::printf("xrt::ip(%s) failed: %s\n", nm, e.what());
            }
        }
        if (!ip) { std::fprintf(stderr, "FATAL: could not open the IP\n"); return 1; }

        // SANITY-CHECK the control register instead of merely printing it.
        // On hardware this returned 0xdeadfa11 -- a poison pattern meaning the
        // AXI-Lite read did not reach the kernel -- and the run continued as if
        // the register interface worked. A valid ap_ctrl_hs value has nothing
        // set above bit 7, and an idle kernel has bit 2 set.
        const uint32_t ctrl0 = ip.read_register(R_CTRL);
        std::printf("control register: 0x%08x\n", ctrl0);
        if (ctrl0 == 0xdeadfa11u || (ctrl0 & 0xffffff00u) != 0u) {
            std::fprintf(stderr,
                        "FATAL: control register reads 0x%08x, which is not a valid\n"
                        "ap_ctrl_hs value. The register path is not working; refusing\n"
                        "to drive the kernel blind.\n", ctrl0);
            return 1;
        }
        if (!(ctrl0 & CTRL_IDLE)) {
            std::fprintf(stderr, "FATAL: kernel is not idle (ctrl=0x%08x)\n", ctrl0);
            return 1;
        }
        std::printf("control register valid and kernel idle\n");

        auto w32 = [&](uint32_t off, uint32_t v) { ip.write_register(off, v); };
        auto w64 = [&](uint32_t off, uint64_t v) {
            ip.write_register(off,     (uint32_t)(v & 0xffffffffu));
            ip.write_register(off + 4, (uint32_t)(v >> 32));
        };

        // Addresses are written once; only the scalars change per run.
        w64(A_M0, bo[0].address());
        w64(A_M1, bo[1].address());
        w64(A_M2, bo[2].address());
        w64(A_M3, bo[3].address());
        w64(A_OUT, bo_out.address());
        std::printf("argument registers programmed\n");

        int trace = 2;
        auto run_one = [&](unsigned mode, unsigned chains, unsigned iters)
            -> std::pair<double, uint64_t> {
            const bool v = (trace-- > 0);
            w32(A_MODE, mode);
            w32(A_CHAINS, chains);
            w32(A_ITERS, iters);
            w64(A_WORDS, g_words_per_port);

            // Timed across start -> done only, so this excludes the launch
            // overhead that a wall-clock measurement around xrt::run would
            // have included. Better measurement than the path that crashed.
            const double t0 = now_s();
            w32(R_CTRL, CTRL_START);

            double dt = 0.0;
            bool done = false;
            const double deadline = t0 + 300.0;
            while (now_s() < deadline) {
                const uint32_t c = ip.read_register(R_CTRL);
                if (c & CTRL_DONE) { dt = now_s() - t0; done = true; break; }
            }
            if (!done) {
                std::fprintf(stderr, "TIMEOUT waiting for ap_done "
                                     "(mode=%u chains=%u iters=%u)\n",
                             mode, chains, iters);
                return {0.0, 0};
            }
            if (v) std::printf("    [ip] mode=%u chains=%u iters=%u -> %.6f s\n",
                               mode, chains, iters, dt);

            bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
            auto *o = bo_out.map<uint64_t *>();
            return {dt, o[1]};
        };

        auto timed = [&](unsigned mode, unsigned chains, unsigned probe_iters)
            -> std::tuple<double, uint64_t, unsigned> {
            auto cal = run_one(mode, chains, probe_iters);
            if (cal.first <= 0.0 || cal.second == 0)
                return std::make_tuple(cal.first, cal.second, probe_iters);
            const double rate = cal.second / cal.first;
            const unsigned per_iter = (mode == 0) ? chains : 4u;
            double want = (rate * (g_quick ? 0.05 : 1.0)) / per_iter;
            if (want < 1000.0) want = 1000.0;
            if (want > 2.0e8) want = 2.0e8;
            const unsigned iters = (unsigned)want;
            auto real = run_one(mode, chains, iters);
            return std::make_tuple(real.first, real.second, iters);
        };

        std::printf("\n=== smallest possible run first ===\n");
        {
            auto r = run_one(1, 0, 1);
            if (r.second == 0) { std::fprintf(stderr, "FATAL: minimal run did nothing\n"); return 1; }
            std::printf("minimal run ok: %llu accesses\n", (unsigned long long)r.second);
        }

        bool any_fail = false;

        std::printf("\n=== MODE_CHASE: dependent pointer chases, one port ===\n");
        std::printf("%8s %12s %12s %12s %12s %14s\n", "chains", "accesses",
                    "seconds", "ns/access", "Maccess/s", "GB/s HBM");
        std::vector<unsigned> sweep = g_quick
            ? std::vector<unsigned>{1u, 8u, 64u}
            : std::vector<unsigned>{1u, 2u, 4u, 8u, 16u, 32u, 48u, 64u, 96u,
                                    128u, 162u, 192u, 256u};
        for (unsigned chains : sweep) {
            auto tr = timed(0, chains, 20000u / chains + 1u);
            const double dt = std::get<0>(tr);
            const uint64_t acc = std::get<1>(tr);
            const unsigned iters = std::get<2>(tr);
            const uint64_t want = (uint64_t)chains * iters;
            if (acc != want) {
                std::printf("%8u  ASSERT FAILED: did %llu, asked %llu\n", chains,
                            (unsigned long long)acc, (unsigned long long)want);
                any_fail = true;
                continue;
            }
            const double rate = acc / dt;
            std::printf("%8u %12llu %12.4f %12.2f %12.1f %14.2f\n", chains,
                        (unsigned long long)acc, dt, 1e9 / rate, rate / 1e6,
                        rate * 32.0 / 1e9);
        }

        std::printf("\n=== MODE_STREAM: independent random, four ports ===\n");
        std::printf("%12s %12s %12s %12s %14s\n", "accesses", "seconds",
                    "Maccess/s", "GB/s useful", "GB/s HBM");
        for (unsigned rep = 0; rep < (g_quick ? 1u : 3u); rep++) {
            auto tr = timed(1, 0, 100000u);
            const double dt = std::get<0>(tr);
            const uint64_t acc = std::get<1>(tr);
            const unsigned iters = std::get<2>(tr);
            const uint64_t want = (uint64_t)iters * 4ULL;
            if (acc != want) {
                std::printf("ASSERT FAILED: did %llu, asked %llu\n",
                            (unsigned long long)acc, (unsigned long long)want);
                any_fail = true;
                continue;
            }
            const double rate = acc / dt;
            std::printf("%12llu %12.4f %12.1f %12.2f %14.2f\n",
                        (unsigned long long)acc, dt, rate / 1e6,
                        rate * 8.0 / 1e9, rate * 32.0 / 1e9);
        }

        if (any_fail) {
            std::printf("\nRESULT_HBM FAIL a point did not do the work it reported\n");
            return 1;
        }
        std::printf("\nRESULT_HBM PASS all access counts asserted\n");
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FATAL: %s\n", e.what());
        return 1;
    }
}
