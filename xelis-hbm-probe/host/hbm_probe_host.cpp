// SPDX-License-Identifier: MIT
//
// Host for the HBM random-access probe. Sweeps chain count in one run, so the
// whole latency curve comes out of a single four-hour link.
//
// Reports, for every point:
//   ns/access        -- at chains=1 this IS the round-trip memory latency
//   Maccess/s        -- achieved random 8-byte access rate
//   GB/s useful      -- accesses x 8 bytes
//   GB/s HBM traffic -- accesses x 32 bytes, HBM2's access granularity, which
//                       is what the memory system actually spends
//
// The access count is read back from the kernel and ASSERTED against what was
// asked for. A benchmark that reports a rate without proving the work happened
// is the same failure mode as a testbench printing PASS having checked nothing.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"

namespace {

// 64 MiB per port, not 256. Still vastly larger than any cache, so the access
// pattern is just as random, but it removes a 1 GiB total allocation as a
// suspect for the SIGBUS. Raise it again once the probe is known to work.
// Overridable via the environment so emulation can run a tiny version of the
// same binary. Debugging this on hardware cost four production windows before
// anyone ran it in emulation once; the footprint being a compile-time constant
// was part of why.
//   XELIS_WORDS_LOG2  words per port, log2 (default 23 = 64 MiB)
//   XELIS_QUICK       if set, three sweep points and short runs
uint64_t g_words_per_port = 1ULL << 23;
uint64_t g_bytes_per_port = (1ULL << 23) * sizeof(uint64_t);
bool     g_quick = false;

double now_s() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <xclbin> [device_index]\n", argv[0]);
        return 2;
    }
    // Unbuffered: the previous run died with SIGBUS and every progress line
    // was still sitting in the stdio buffer, so the log showed the crash and
    // nothing about where it happened. Buffered diagnostics are no diagnostics.
    setvbuf(stdout, nullptr, _IONBF, 0);

    const std::string xclbin = argv[1];
    const unsigned dev_index = (argc > 2) ? std::strtoul(argv[2], nullptr, 10) : 0;

    if (const char *e = std::getenv("XELIS_WORDS_LOG2")) {
        unsigned lg = std::strtoul(e, nullptr, 10);
        if (lg < 10 || lg > 28) { std::fprintf(stderr, "XELIS_WORDS_LOG2 must be 10..28\n"); return 2; }
        g_words_per_port = 1ULL << lg;
        g_bytes_per_port = g_words_per_port * sizeof(uint64_t);
    }
    g_quick = (std::getenv("XELIS_QUICK") != nullptr);
    std::printf("words/port=%llu (%llu MiB)  quick=%d\n",
                (unsigned long long)g_words_per_port,
                (unsigned long long)(g_bytes_per_port >> 20), (int)g_quick);

    try {
        auto device = xrt::device(dev_index);
        auto uuid = device.load_xclbin(xclbin);
        auto krnl = xrt::kernel(device, uuid, "hbm_probe");

        // Validate the kernel object BEFORE constructing a run from it. The
        // SIGBUS lands inside xrt::run(krnl), which is what a kernel handle
        // that resolved to no compute unit would do. The xclbin names the CU
        // hbm_probe_1 (nk=hbm_probe:1:hbm_probe_1) while this asks for
        // "hbm_probe" and relies on XRT matching it.
        try {
            std::printf("kernel name reported: %s\n", krnl.get_name().c_str());
        } catch (const std::exception &e) {
            std::printf("kernel get_name threw: %s\n", e.what());
        }

        std::printf("xclbin loaded: %s\n", xclbin.c_str());
        std::printf("footprint: %llu MiB per port, 4 ports\n",
                    (unsigned long long)(g_bytes_per_port >> 20));

        // Four data buffers, each in its own HBM group, plus the result buffer.
        for (int i = 0; i < 9; i++)
            std::printf("  arg %d -> memory group %d\n", i, krnl.group_id(i));

        std::vector<xrt::bo> bo;
        for (int i = 0; i < 4; i++) {
            std::printf("allocating port %d: %llu MiB in group %d ... ", i,
                        (unsigned long long)(g_bytes_per_port >> 20),
                        krnl.group_id(i));
            bo.emplace_back(device, g_bytes_per_port, krnl.group_id(i));
            std::printf("ok\n");
        }
        // 4 KiB, not 64 bytes: XRT wants page-sized buffers and a 64-byte BO is
        // another candidate for the SIGBUS.
        std::printf("allocating result buffer in group %d ... ",
                    krnl.group_id(8));
        auto bo_out = xrt::bo(device, 4096, krnl.group_id(8));
        std::printf("ok\n");

        // Fill with random data. The values ARE the pointer chain, so zeros
        // would make every chase collapse onto one address and the probe would
        // measure a cache hit instead of random access.
        std::printf("filling %llu MiB of HBM with random data...\n",
                    (unsigned long long)((g_bytes_per_port * 4) >> 20));
        {
            std::mt19937_64 rng(0xC1100);
            std::vector<uint64_t> chunk(1ULL << 20);
            for (int i = 0; i < 4; i++) {
                std::printf("  port %d: mapping ... ", i);
                auto *map = bo[i].map<uint64_t *>();
                std::printf("mapped, filling ... ");
                for (uint64_t off = 0; off < g_words_per_port; off += chunk.size()) {
                    for (auto &w : chunk) w = rng();
                    std::memcpy(map + off, chunk.data(),
                                chunk.size() * sizeof(uint64_t));
                }
                bo[i].sync(XCL_BO_SYNC_BO_TO_DEVICE);
                std::printf("synced\n");
            }
        }
        std::printf("all buffers ready\n");

        // Step-by-step, because the first hardware attempt died with SIGBUS
        // somewhere in here and a stack-free signal tells you nothing about
        // which call it was. Verbose only for the first few invocations.
        int trace = 3;
        auto run_one = [&](unsigned mode, unsigned chains, unsigned iters)
            -> std::pair<double, uint64_t> {
            const bool v = (trace-- > 0);
            if (v) std::printf("    [run] mode=%u chains=%u iters=%u\n", mode, chains, iters);

            if (v) std::printf("    [run] constructing xrt::run ... \n");
            auto run = xrt::run(krnl);
            if (v) std::printf("ok\n");

            if (v) std::printf("    [run] set_arg 0..3 (buffers) ... \n");
            run.set_arg(0, bo[0]);
            run.set_arg(1, bo[1]);
            run.set_arg(2, bo[2]);
            run.set_arg(3, bo[3]);
            if (v) std::printf("ok\n");

            if (v) std::printf("    [run] set_arg 4..7 (scalars) ... \n");
            run.set_arg(4, mode);
            run.set_arg(5, chains);
            run.set_arg(6, iters);
            run.set_arg(7, (uint64_t)g_words_per_port);
            if (v) std::printf("ok\n");

            if (v) std::printf("    [run] set_arg 8 (out) ... \n");
            run.set_arg(8, bo_out);
            if (v) std::printf("ok\n");

            const double t0 = now_s();
            if (v) std::printf("    [run] start ... \n");
            run.start();
            if (v) std::printf("started, waiting ... \n");
            run.wait();
            const double dt = now_s() - t0;
            if (v) std::printf("done in %.4f s\n", dt);

            if (v) std::printf("    [run] sync FROM_DEVICE ... \n");
            bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
            if (v) std::printf("ok\n");

            if (v) std::printf("    [run] map result ... \n");
            auto *o = bo_out.map<uint64_t *>();
            if (v) std::printf("mapped at %p\n", (void *)o);

            if (v) std::printf("    [run] reading o[0], o[1] ... \n");
            const uint64_t chk = o[0];
            const uint64_t acc = o[1];
            if (v) std::printf("checksum=0x%llx accesses=%llu\n",
                               (unsigned long long)chk, (unsigned long long)acc);
            return {dt, acc};
        };

        // Smallest possible invocation first. If the kernel interface is wrong,
        // fail here with one access rather than inside a sweep.
        std::printf("@=== minimal invocation: MODE_STREAM, 1 iteration ===\n");
        {
            auto r = run_one(1, 0, 1);
            std::printf("minimal run ok: %.6f s, %llu accesses\n",
                        r.first, (unsigned long long)r.second);
        }

        std::printf("\nwarming up...\n");
        // Size each point so it runs for about a second. The achieved rate
        // spans ~75x across this sweep -- latency-bound at chains=1, fully
        // pipelined at 256 -- so a fixed iteration count would leave the fast
        // points finishing in milliseconds, where kernel launch overhead is
        // most of what gets timed. Calibrate with a short run, then size the
        // real one from the measured rate.
        auto timed = [&](unsigned mode, unsigned chains, unsigned probe_iters)
            -> std::tuple<double, uint64_t, unsigned> {
            auto cal = run_one(mode, chains, probe_iters);
            if (cal.first <= 0.0 || cal.second == 0)
                return std::make_tuple(cal.first, cal.second, probe_iters);
            const double rate = cal.second / cal.first;      // accesses/s
            const unsigned per_iter = (mode == 0) ? chains : 4u;
            double want = (rate * (g_quick ? 0.02 : 1.0)) / per_iter;
            if (want < 1000.0) want = 1000.0;
            if (want > 2.0e8) want = 2.0e8;
            const unsigned iters = (unsigned)want;
            auto real = run_one(mode, chains, iters);
            return std::make_tuple(real.first, real.second, iters);
        };

        run_one(0, 8, 1000);

        std::printf("\n=== MODE_CHASE: dependent pointer chases, one port ===\n");
        std::printf("%8s %12s %12s %12s %12s %14s\n", "chains", "accesses",
                    "seconds", "ns/access", "Maccess/s", "GB/s HBM");
        bool any_fail = false;
        std::vector<unsigned> sweep = g_quick
            ? std::vector<unsigned>{1u, 8u, 64u}
            : std::vector<unsigned>{1u, 2u, 4u, 8u, 16u, 32u, 48u, 64u, 96u,
                                    128u, 162u, 192u, 256u};
        for (unsigned chains : sweep) {
            // Keep total work roughly constant so every point takes a similar
            // time and none is dominated by launch overhead.
            auto tr = timed(0, chains, 20000u / chains + 1u);
            const double dt = std::get<0>(tr);
            const uint64_t acc = std::get<1>(tr);
            const unsigned iters = std::get<2>(tr);
            const uint64_t want = (uint64_t)chains * iters;
            if (acc != want) {
                std::printf("%8u  ASSERT FAILED: kernel did %llu accesses, "
                            "asked for %llu\n", chains,
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
                std::printf("ASSERT FAILED: kernel did %llu accesses, asked "
                            "for %llu\n", (unsigned long long)acc,
                            (unsigned long long)want);
                any_fail = true;
                continue;
            }
            const double rate = acc / dt;
            std::printf("%12llu %12.4f %12.1f %12.2f %14.2f\n",
                        (unsigned long long)acc, dt, rate / 1e6,
                        rate * 8.0 / 1e9, rate * 32.0 / 1e9);
        }

        if (any_fail) {
            std::printf("\nRESULT_HBM FAIL at least one point did not do the "
                        "work it reported\n");
            return 1;
        }
        std::printf("\nRESULT_HBM PASS all access counts asserted\n");
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FATAL: %s\n", e.what());
        return 1;
    }
}
