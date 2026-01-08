#!/usr/bin/env julia

"""
Memory and resource debugging test
"""

using Pkg
Pkg.activate(".")
using Dates
using Euphemia

println("🧠 MEMORY AND RESOURCE DEBUGGING")
println("="^40)

# Function to check memory usage
function check_memory()
    # Get process memory info
    mem_info = read(`ps -o pid,vsz,rss,pmem -p $(getpid())`, String)
    println("   💾 Memory status:")
    println("   $mem_info")

    # Julia GC stats
    gc_stats = Base.gc_num()
    println("   🗑️  GC stats: $(gc_stats.total_time/1e9) seconds total, $(gc_stats.full_sweep) full sweeps")

    # Available system memory
    try
        meminfo = read("/proc/meminfo", String)
        available_match = match(r"MemAvailable:\s*(\d+) kB", meminfo)
        if available_match !== nothing
            available_gb = parse(Int, available_match.captures[1]) / 1024 / 1024
            println("   🖥️  System available memory: $(round(available_gb, digits=1)) GB")
        end
    catch
        println("   🖥️  System memory info not available")
    end
end

# Test with very small zone that should not have memory issues
test_zones = ["AL"]  # Just one small zone
test_dates = [Date(2024, 6, 18), Date(2024, 6, 19)]

println("📅 Testing $(length(test_dates)) dates with $(length(test_zones)) zones")
println("🔍 Monitoring memory at each step...")
println()

check_memory()

order_book_count = 0
for (date_idx, date) in enumerate(test_dates)
    println("\n📅 DATE $date_idx: $date")
    println("-"^30)

    for (zone_idx, zone) in enumerate(test_zones)
        order_book_count += 1
        println("\n🌍 ORDER BOOK #$order_book_count: $zone on $date")

        println("📊 BEFORE order book creation:")
        check_memory()

        # Force garbage collection before each order book
        GC.gc()
        println("   🗑️  Forced garbage collection")

        try
            println("🔄 Creating order book...")
            start_time = time()

            # Just create the order book - don't run optimization yet
            order_book_result = Euphemia.create_adjusted_order_book(zone, date; random_seed=42)

            elapsed = time() - start_time

            if order_book_result.success
                num_orders = length(order_book_result.order_book.orders)
                println("   ✅ Order book created: $num_orders orders in $(round(elapsed, digits=1))s")
            else
                println("   ❌ Order book failed: $(order_book_result.message)")
            end

        catch e
            println("   💥 ERROR creating order book: $e")
            println("   📊 Memory state when error occurred:")
            check_memory()
            break
        end

        println("📊 AFTER order book creation:")
        check_memory()

        # Check if we're the problematic 5th order book
        if order_book_count == 5
            println("\n🚨 REACHED ORDER BOOK #5 - This is where hangs typically occur!")
            println("📊 Detailed memory analysis:")
            check_memory()

            # Try to create one more order book with detailed monitoring
            println("\n🔍 Attempting to create next order book with monitoring...")

            # Set up a timer to monitor progress
            timeout = 30  # 30 second timeout
            start_time = time()

            # Start monitoring task
            monitor_task = @async begin
                while time() - start_time < timeout
                    sleep(2)
                    elapsed = time() - start_time
                    println("     ⏱️  Still working... $(round(elapsed, digits=1))s elapsed")
                    check_memory()
                end
                println("     ⏰ Timeout reached!")
            end

            # Try the next operation
            try
                if date_idx < length(test_dates) && zone_idx == length(test_zones)
                    # Move to next date
                    next_date = test_dates[date_idx+1]
                    next_zone = test_zones[1]
                    println("     🔄 Creating order book for $next_zone on $next_date...")

                    result = Euphemia.create_adjusted_order_book(next_zone, next_date; random_seed=42)

                    if result.success
                        println("     ✅ SUCCESS: Order book #$(order_book_count + 1) created!")
                    else
                        println("     ❌ FAILED: $(result.message)")
                    end
                end
            catch e
                println("     💥 ERROR: $e")
            finally
                # Cancel monitoring
                Base.throwto(monitor_task, InterruptException())
            end

            break
        end

        # Small delay to make output readable
        sleep(1)
    end

    if order_book_count >= 5
        break
    end
end

println("\n🏁 Memory debugging complete")
println("Order books created before issue: $order_book_count")