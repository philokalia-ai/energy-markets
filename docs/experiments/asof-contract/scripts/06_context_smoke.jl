using Euphemia, Dates, DataFrames
using Euphemia: with_context, gate_context, issuance_context, asof_audit_table, reset_asof_audit!
d = Date(2026, 8, 20)
out = open(ARGS[1], "w")
P(args...) = println(out, args...)
# --- outage table: legacy vs gate context
Euphemia.clear_generator_caches!()
o_leg = Euphemia.get_day_outages(d)
o_ctx = with_context(gate_context(d)) do
    Euphemia.get_day_outages(d)
end
a_leg = Set(String.(o_leg.asset_code)); a_ctx = Set(String.(o_ctx.asset_code))
P("=== get_day_outages $d: legacy rows=", nrow(o_leg), " ctx rows=", nrow(o_ctx),
  " only-legacy=", length(setdiff(a_leg, a_ctx)), " only-ctx=", length(setdiff(a_ctx, a_leg)))
j = innerjoin(select(o_leg, :asset_code, :available_capacity_mw => :leg), select(o_ctx, :asset_code, :available_capacity_mw => :ctx), on=:asset_code)
P("    shared assets with different available_capacity: ", count(j.leg .!= j.ctx), " of ", nrow(j))
# --- p95 window: legacy vs ctx for DE_LU
p_leg = Euphemia.MeritOrderBook.get_type_output_p95("DE_LU", d)
p_ctx = with_context(gate_context(d)) do
    Euphemia.MeritOrderBook.get_type_output_p95("DE_LU", d)
end
P("=== p95 DE_LU by type (legacy → ctx), only where different:")
for k in sort(collect(keys(p_leg)))
    a = p_leg[k]; b = get(p_ctx, k, NaN)
    abs(a - b) > 1e-6 && P("    ", rpad(k, 32), round(a; digits=1), " → ", round(b; digits=1))
end
# --- audit
reset_asof_audit!()
with_context(gate_context(d)) do
    Euphemia.create_merit_order_book("DE_LU", d)
end
P("=== audit, DE_LU book under gate context:")
show(out, MIME"text/plain"(), asof_audit_table()); P()
reset_asof_audit!()
with_context(issuance_context(d, 3)) do
    Euphemia.create_merit_order_book("DE_LU", d)
end
P("=== audit, DE_LU book under lead-3 issuance context:")
show(out, MIME"text/plain"(), asof_audit_table()); P()
# --- tx outage caps
t_leg = Euphemia.Network.tx_outage_caps(d)
t_ctx = with_context(gate_context(d)) do
    Euphemia.Network.tx_outage_caps(d)
end
P("=== tx_outage_caps: legacy n=", length(t_leg), " ctx n=", length(t_ctx), " equal=", t_leg == t_ctx)
P("    cache keys: ", collect(keys(Euphemia.Network._TX_OUTAGE_DAY_CACHE)))
close(out)
