#!/usr/bin/env python3
"""Does the reference's floating-point isqrt equal floor(sqrt(n)) for every u64?

The RTL in xelis_prims.sv assumes it does, and implements exact integer sqrt on
that basis. This script tests the assumption before anything is built on it.

The reference (src/v3.rs):

    pub fn isqrt(n: u64) -> u64 {
        if n < 2 { return n; }
        let approx = (n as f64).sqrt() as u64;
        if approx.wrapping_mul(approx) > n { approx - 1 }
        else if (approx + 1).wrapping_mul(approx + 1) <= n { approx + 1 }
        else { approx }
    }

Python's float is IEEE-754 binary64 and math.sqrt is correctly rounded, exactly
as Rust's f64, so this is a faithful model rather than an approximation. The one
thing needing care is `wrapping_mul`, which is where the interesting behaviour
lives.
"""

import math
import random
import sys

U64 = 1 << 64


def wrapping_mul(a: int, b: int) -> int:
    return (a * b) % U64


def ref_isqrt(n: int) -> int:
    """The reference, transcribed literally including the wrapping."""
    if n < 2:
        return n
    approx = int(math.sqrt(float(n)))          # Rust: (n as f64).sqrt() as u64
    if wrapping_mul(approx, approx) > n:
        return approx - 1
    elif wrapping_mul(approx + 1, approx + 1) <= n:
        return approx + 1
    else:
        return approx


def exact_isqrt(n: int) -> int:
    """What the RTL computes: floor(sqrt(n)), exactly."""
    return math.isqrt(n)


def main() -> int:
    mismatches = []
    checked = 0

    def check(n: int, label: str) -> None:
        nonlocal checked
        checked += 1
        r, e = ref_isqrt(n), exact_isqrt(n)
        if r != e:
            mismatches.append((n, r, e, label))

    # 1. Everything small, exhaustively.
    for n in range(0, 1_000_001):
        check(n, "small")

    # 2. Perfect squares and their neighbours across the whole range. These are
    #    where an off-by-one in the correction would show up.
    for k in list(range(0, 4096)) + [
        (1 << 16) - 1, 1 << 16,
        (1 << 31) - 1, 1 << 31,
        (1 << 32) - 3, (1 << 32) - 2, (1 << 32) - 1, 1 << 32,
    ]:
        for d in (-2, -1, 0, 1, 2):
            n = k * k + d
            if 0 <= n < U64:
                check(n, "square+/-d")

    # 3. The very top of the range, exhaustively over the last stretch.
    for n in range(U64 - 2_000_000, U64):
        check(n, "top")

    # 4. Powers of two and their neighbours.
    for s in range(0, 64):
        for d in (-1, 0, 1):
            n = (1 << s) + d
            if 0 <= n < U64:
                check(n, "pow2")

    # 5. Random, weighted towards the high end where f64 loses precision.
    rng = random.Random(0xC1100)
    for _ in range(400_000):
        check(rng.randrange(U64), "random-full")
    for _ in range(400_000):
        check(rng.randrange(U64 - (1 << 40), U64), "random-high")
    for _ in range(200_000):
        check(rng.randrange(1 << 53, U64), "random-above-2^53")

    print("checked=%d" % checked)
    if checked == 0:
        print("RESULT_ISQRT FAIL checked nothing")
        return 2

    print("mismatches=%d" % len(mismatches))
    if not mismatches:
        print("RESULT_ISQRT PASS reference == floor(sqrt(n)) on every value tested")
        return 0

    # Characterise the failures rather than just listing them.
    by_delta = {}
    for n, r, e, label in mismatches:
        by_delta.setdefault(r - e, []).append((n, r, e, label))

    print("RESULT_ISQRT FAIL")
    print("distribution of (reference - exact):")
    for d in sorted(by_delta):
        print("   delta=%+d  count=%d" % (d, len(by_delta[d])))

    print("smallest mismatching n by delta:")
    for d in sorted(by_delta):
        n, r, e, label = min(by_delta[d], key=lambda t: t[0])
        print("   delta=%+d  n=%d (%s)" % (d, n, label))
        print("            reference=%d  exact=%d" % (r, e))
        approx = int(math.sqrt(float(n)))
        print("            approx=%d  approx^2 wrapped=%d  (approx+1)^2 wrapped=%d"
              % (approx, wrapping_mul(approx, approx),
                 wrapping_mul(approx + 1, approx + 1)))
        print("            true approx^2=%d  2^64=%d  overflowed=%s"
              % (approx * approx, U64, approx * approx >= U64))
    return 1


if __name__ == "__main__":
    sys.exit(main())
