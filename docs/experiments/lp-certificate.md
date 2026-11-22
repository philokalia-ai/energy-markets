# LP certificate for the MPCC solve (cv46, November 2026)

**What.** `solve_mpcc_market_clearing` used to solve every MPCC as a big-M complementarity MIP.
It now solves it by two LPs (`src/mpcc/lp_certificate.jl`):

1. **Welfare LP**: the MPCC with every price-side object removed (duals, prices, congestion rents,
   complementarity binaries and the rows that touch them): acceptances ≤ 1, ATC bounds, JAO
   net-position rows, nodal balance with shed, the same welfare objective. Its optimum is an
   upper bound on the MPCC welfare.
2. **Fixed-pattern LP**: every complementarity binary is set by rule from that dispatch
   (order rejected / partially / fully accepted; link at its forward / backward ATC limit) and
   fixed; the remaining MPCC is an LP. If it is optimal at the welfare-LP objective the MPCC is
   solved to optimality: prices exist for the welfare-optimal dispatch.

If the certificate fails, the pattern becomes the MIP start and the MIP (with its unchanged retry
ladder) solves the period. That is expected exactly where the MPCC price conditions cannot price
the welfare optimum, e.g. an active JAO net-position row (unpriced in the MPCC coupling row; the
exact NP constraint is opt-in on the record path) — `test/test_lp_certificate.jl` pins such a case.

**Evidence** (highs-blocks research, `research/highs-blocks-mono`, HiGHS 1.16.0 JLL):
- cv45 production config, 31 record days (every 6th of the cv45 singles list), certificate vs the
  MIP-first clear in separate results DBs: 29,016 / 29,016 saved price cells byte-identical (`==`);
  1,488 / 1,488 period solves certified; MIP-first output equal to the cv45 reference (c1) on all
  cells; median day 116 s vs 178 s, pass-2 pricing 5.8 s vs 72 s (the first certificate call of a
  fresh process pays ~60 s of JIT).
- Complex-order books (`EUPHEMIA_COMPLEX_ORDERS=blocks` / `ps,blocks`, 4 days, every PAB round incl.
  fallbacks), shadow mode: 1,176 / 1,176 certified, 45,864 / 45,864 published cells identical.
- Full cv45 record (2024-07-01..2026-11-14, 866 days) re-cleared with this code vs the cv45 record:
  0 MIP fallbacks in 41,614 period solves; 809,611 / 809,616 prices identical. The 5 others (RS
  2025-11-19 18:00, SE3 2026-11-02 20:00, BG 2026-09-05 11:00, NO3/NO5 2025-05-09 08:00) are
  equal-welfare ties: same objective to ≤ 1 ulp, a different flow pattern at an ATC limit, which the
  price reconstruction maps to a different price component; the MIP-first path flips on the same
  cells under ulp-level input changes. Day median 59 s vs 261 s.

**Why it works.** Without inter-temporal coupling and without unpriced primal rows, the MPCC's
price conditions are the KKT conditions of the welfare LP, so the welfare optimum is an MPCC
optimum (the monolithic 24-period MPCC's root LP bound already equals the decomposed optimum); the
MIP's difficulty was only finding the binaries, which the LP dispatch determines.
