# Trial single-zone merit book builds for AL / MK / ME / HR (iter9 scoping).
# Book CONSTRUCTION only — no clearing, no solver. Postgres READ-ONLY.
# Run: julia --project=. docs/experiments/iter9-scoping/trial_books.jl
using Dates
using Euphemia

const ZONES = ["AL", "MK", "ME", "HR"]
const DAYS  = [Date(2026, 1, 21), Date(2026, 4, 3), Date(2026, 6, 10)]

results = []
for day in DAYS, zone in ZONES
    println("\n", "="^70)
    println("### $zone $day")
    r = try
        Euphemia.MeritOrderBook.create_merit_order_book(zone, day)
    catch e
        println("EXCEPTION: ", sprint(showerror, e)[1:min(end, 500)])
        push!(results, (zone=zone, day=day, ok=false, msg="exception: $(typeof(e))",
                        n_supply=0, n_demand=0, ratio=NaN))
        continue
    end
    if !r.success
        push!(results, (zone=zone, day=day, ok=false, msg=r.message,
                        n_supply=0, n_demand=0, ratio=NaN))
        continue
    end
    ob = r.order_book
    # supply/demand MWh totals over the day (all orders are hourly SimpleOrders here)
    sup = sum(o.quantity for o in ob.orders if o.type == :supply; init=0.0)
    dem = sum(o.quantity for o in ob.orders if o.type == :demand; init=0.0)
    nsup = count(o -> o.type == :supply, ob.orders)
    ndem = count(o -> o.type == :demand, ob.orders)
    # per-slot min ratio (worst hour): supply available vs demand requested
    slots = unique([o.date_time for o in ob.orders])
    worst = minimum(
        (sum(o.quantity for o in ob.orders if o.type == :supply && o.date_time == t; init=0.0) /
         max(sum(o.quantity for o in ob.orders if o.type == :demand && o.date_time == t; init=0.0), 1e-9))
        for t in slots)
    push!(results, (zone=zone, day=day, ok=true, msg="",
                    n_supply=nsup, n_demand=ndem,
                    ratio=round(sup / max(dem, 1e-9), digits=2)))
    println(">>> $zone $day OK: $nsup supply + $ndem demand orders; " *
            "day supply/demand MWh ratio $(round(sup/max(dem,1e-9), digits=2)); " *
            "worst-hour ratio $(round(worst, digits=2))")
end

println("\n", "="^70)
println("SUMMARY")
for r in results
    println(rpad("$(r.zone) $(r.day)", 16), r.ok ? "OK  ratio=$(r.ratio)  ($(r.n_supply)S/$(r.n_demand)D)" : "FAIL: $(r.msg)")
end
