#!/usr/bin/env julia

"""
Simple test to reproduce the 5th order book hang issue
"""

using Pkg
Pkg.activate(".")
using Dates
using Euphemia

println("🧠 TESTING 5TH ORDER BOOK HANG ISSUE")
println("="^40)

# Test with minimal zones to isolate the issue
test_zones = ["AL", "BG"]  # Two small zones
test_dates = [Date(2024, 6, 18), Date(2024, 6, 19), Date(2024, 6, 20)]  # Three dates

order_book_count = 0

println("📅 Testing $(length(test_dates)) dates with $(length(test_zones)) zones")
println("🎯 Looking for hang at order book #5...")
println()

for (date_idx, date) in enumerate(test_dates)
    println("\n📅 DATE $date_idx: $date")

    for (zone_idx, zone) in enumerate(test_zones)
        global order_book_count += 1

        println("\n🌍 ORDER BOOK #$order_book_count: $zone on $date")

        # Force GC before each order book
        GC.gc()

        start_time = time()

        try
            if order_book_count <= 4
                # First 4 should work normally
                println("   🔄 Creating order book (should work)...")
                result = Euphemia.create_adjusted_order_book(zone, date; random_seed=42)
                elapsed = time() - start_time

                if result.success
                    println("   ✅ SUCCESS in $(round(elapsed, digits=1))s")
                else
                    println("   ❌ FAILED: $(result.message)")
                end

            elseif order_book_count == 5
                # This is where it should hang
                println("   🚨 CRITICAL TEST: ORDER BOOK #5")
                println("   🔄 Creating order book (this might hang)...")

                # Set up timeout monitoring
                monitor_start = time()
                timeout = 60  # 60 second timeout

                # Run with timeout
                order_book_task = @async Euphemia.create_adjusted_order_book(zone, date; random_seed=42)

                while !istaskdone(order_book_task) && (time() - monitor_start) < timeout
                    sleep(5)
                    elapsed = time() - monitor_start
                    println("     ⏱️  Still processing order book #5... $(round(elapsed, digits=1))s")

                    # Check memory
                    try
                        rss_kb = parse(Int, split(read(`ps -o rss= -p $(getpid())`, String))[1])
                        rss_mb = round(rss_kb / 1024, digits=1)
                        println("     💾 Memory: $(rss_mb) MB")
                    catch
                    end
                end

                if istaskdone(order_book_task)
                    result = fetch(order_book_task)
                    elapsed = time() - start_time
                    if result.success
                        println("   ✅ Order book #5 SUCCESS in $(round(elapsed, digits=1))s")
                        println("   🎉 No hang detected!")
                    else
                        println("   ❌ Order book #5 FAILED: $(result.message)")
                    end
                else
                    println("   ⏰ ORDER BOOK #5 TIMEOUT - HANG CONFIRMED!")
                    println("   🛑 Terminating hung task...")
                    Base.throwto(order_book_task, InterruptException())
                    break
                end

            else
                # Continue testing if #5 worked
                println("   🔄 Creating order book #$order_book_count...")
                result = Euphemia.create_adjusted_order_book(zone, date; random_seed=42)
                elapsed = time() - start_time

                if result.success
                    println("   ✅ SUCCESS in $(round(elapsed, digits=1))s")
                else
                    println("   ❌ FAILED: $(result.message)")
                end
            end

        catch e
            elapsed = time() - start_time
            println("   💥 ERROR in order book #$order_book_count after $(round(elapsed, digits=1))s: $e")
        end

        # Stop if we confirmed the hang or got past it
        if order_book_count >= 6
            println("\n✅ Made it past order book #5 - no systematic hang detected")
            break
        end
    end

    if order_book_count >= 6
        break
    end
end

println("\n🏁 Test complete")
println("📊 Total order books attempted: $order_book_count")

if order_book_count < 5
    println("❌ Test failed before reaching order book #5")
elseif order_book_count == 4
    println("⏰ Hang confirmed at order book #5")
else
    println("✅ No hang detected - issue may be intermittent or environment-specific")
end