#!/usr/bin/env python3
"""A closed form for the reference isqrt, including its overflow behaviour.

verify_isqrt.py showed the reference is NOT floor(sqrt(n)): for large n the
`wrapping_mul` in its correction step overflows u64 and it returns a value 1 or
2 too high. This script proposes an exact closed form and tests it, so the RTL
can reproduce the reference bit-for-bit instead of approximating it.

Claim
-----
    n >= 2^64 - 1024          ->  4294967297      (2^32 + 1)
    n >= (2^32 - 1)^2         ->  4294967296      (2^32)
    otherwise                 ->  floor(sqrt(n))

Why those two boundaries:

  * For n >= (2^32-1)^2 the true floor(sqrt(n)) is always 2^32-1, because
    (2^32-1)^2 <= n < 2^64 = (2^32)^2. But `(approx+1)*(approx+1)` is then at
    least 2^64, which wraps to a small value, so the `<= n` test passes and the
    reference increments when it should not.

  * approx itself is 2^32 rather than 2^32-1 exactly when `n as f64` rounds up
    to 2^64. Near 2^64 the binary64 ulp is 2^(64-53) = 2048, so round-to-nearest
    lands on 2^64 iff n >= 2^64 - 1024. In that case approx^2 also wraps, and
    the reference increments from 2^32 to 2^32+1 -- two too high.
"""

import math
import random
import sys

U64 = 1 << 64
BOUND_LO = (1 << 32) - 1
BOUND_LO_SQ = BOUND_LO * BOUND_LO        # 18446744065119617025
BOUND_HI = U64 - 1024                    # 18446744073709550592


def wrapping_mul(a: int, b: int) -> int:
    return (a * b) % U64


def ref_isqrt(n: int) -> int:
    if n < 2:
        return n
    approx = int(math.sqrt(float(n)))
    if wrapping_mul(approx, approx) > n:
        return approx - 1
    elif wrapping_mul(approx + 1, approx + 1) <= n:
        return approx + 1
    else:
        return approx


def closed_form(n: int) -> int:
    """What the RTL should compute. Two constant compares over exact isqrt."""
    if n >= BOUND_HI:
        return (1 << 32) + 1
    if n >= BOUND_LO_SQ:
        return 1 << 32
    return math.isqrt(n)


def main() -> int:
    bad = []
    checked = 0

    def check(n: int, label: str) -> None:
        nonlocal checked
        checked += 1
        if closed_form(n) != ref_isqrt(n):
            bad.append((n, closed_form(n), ref_isqrt(n), label))

    # Exhaustive at the bottom.
    for n in range(0, 200_001):
        check(n, "small")

    # Exhaustive across both proposed boundaries, well past them in each
    # direction. If a boundary is off by one this is what catches it.
    for base, label in ((BOUND_LO_SQ, "boundary-lo"), (BOUND_HI, "boundary-hi")):
        for d in range(-300_000, 300_001):
            n = base + d
            if 0 <= n < U64:
                check(n, label)

    # Exhaustive over the very top.
    for n in range(U64 - 300_000, U64):
        check(n, "top")

    # Perfect squares and neighbours everywhere.
    for k in list(range(0, 3000)) + [
        (1 << 16) - 1, 1 << 16, (1 << 31) - 1, 1 << 31,
        (1 << 32) - 3, (1 << 32) - 2, BOUND_LO, 1 << 32,
    ]:
        for d in (-2, -1, 0, 1, 2):
            n = k * k + d
            if 0 <= n < U64:
                check(n, "square")

    # Dense random inside the divergent range, which is only ~8.59e9 wide.
    rng = random.Random(0x5EED)
    for _ in range(300_000):
        check(rng.randrange(BOUND_LO_SQ, U64), "random-divergent")

    # And random across the whole space, where the closed form must reduce to
    # plain floor(sqrt(n)).
    for _ in range(300_000):
        check(rng.randrange(U64), "random-full")
    for _ in range(200_000):
        check(rng.randrange(1 << 53, U64), "random-high")

    print("checked=%d" % checked)
    if checked == 0:
        print("RESULT_FIX FAIL checked nothing")
        return 2
    print("mismatches=%d" % len(bad))
    if bad:
        print("RESULT_FIX FAIL")
        for n, cf, rf, label in bad[:10]:
            print("   n=%d closed=%d ref=%d (%s)" % (n, cf, rf, label))
        return 1

    # How often does this actually matter?
    width = U64 - BOUND_LO_SQ
    print("RESULT_FIX PASS closed form == reference on every value tested")
    print("divergent range width = %d  (%.3e of the u64 space)"
          % (width, width / U64))
    return 0


if __name__ == "__main__":
    sys.exit(main())
