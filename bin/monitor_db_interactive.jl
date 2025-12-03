n#!/usr/bin/env julia
"""
Database monitoring utilities for parallel energy price generation.

This script provides tools to monitor PostgreSQL connections, performance,
and identify bottlenecks when scaling up parallel workers.
"""

using Euphemia
using DataFrames

# Import database utilities
using Euphemia: sql2df

println("🗄️  DATABASE MONITORING UTILITIES")
println("="^60)

# Function to check current database connections
function check_database_connections()
    println("\n📊 Current Database Connections:")
    println("-"^40)

    query = """
    SELECT 
        state,
        COUNT(*) as connection_count,
        string_agg(DISTINCT application_name, ', ') as applications
    FROM pg_stat_activity 
    WHERE pid != pg_backend_pid()  -- Exclude this query itself
    GROUP BY state
    ORDER BY connection_count DESC;
    """

    try
        df = sql2df(query)
        for row in eachrow(df)
            println("   $(row.state): $(row.connection_count) connections ($(row.applications))")
        end

        # Total connections
        total_query = """
        SELECT COUNT(*) as total_connections
        FROM pg_stat_activity 
        WHERE pid != pg_backend_pid();
        """
        total_df = sql2df(total_query)
        println("   📈 Total active connections: $(total_df.total_connections[1])")

        # Max connections limit
        max_query = "SHOW max_connections;"
        max_df = sql2df(max_query)
        max_conn = parse(Int, max_df.max_connections[1])
        utilization = round(total_df.total_connections[1] / max_conn * 100, digits=1)

        println("   🚨 Connection limit: $max_conn ($(utilization)% used)")

        if utilization > 80
            println("   ⚠️  WARNING: High connection usage! Consider reducing workers.")
        elseif utilization > 60
            println("   💡 CAUTION: Moderate connection usage. Monitor closely.")
        else
            println("   ✅ Connection usage looks healthy.")
        end

    catch e
        println("   ❌ Error checking connections: $e")
    end
end

# Function to check database performance metrics
function check_database_performance()
    println("\n⚡ Database Performance Metrics:")
    println("-"^40)

    # Check for slow queries
    slow_query = """
    SELECT 
        query_start,
        now() - query_start as duration,
        state,
        left(query, 100) as query_preview
    FROM pg_stat_activity 
    WHERE state = 'active' 
      AND query_start < now() - interval '10 seconds'
      AND pid != pg_backend_pid()
    ORDER BY duration DESC
    LIMIT 5;
    """

    try
        df = sql2df(slow_query)
        if nrow(df) > 0
            println("   🐌 Slow running queries (>10s):")
            for row in eachrow(df)
                duration = round(row.duration / 1e9, digits=1)  # Convert nanoseconds to seconds
                println("      $(duration)s: $(row.query_preview)...")
            end
        else
            println("   ✅ No slow queries detected")
        end

        # Check database locks
        lock_query = """
        SELECT 
            mode,
            COUNT(*) as lock_count
        FROM pg_locks 
        GROUP BY mode
        ORDER BY lock_count DESC
        LIMIT 5;
        """

        lock_df = sql2df(lock_query)
        println("   🔒 Active locks by type:")
        for row in eachrow(lock_df)
            println("      $(row.mode): $(row.lock_count)")
        end

    catch e
        println("   ❌ Error checking performance: $e")
    end
end

# Function to check ENTSO-E specific table activity
function check_entsoe_table_activity()
    println("\n📋 ENTSO-E Table Activity:")
    println("-"^40)

    # Check recent queries on main tables
    table_query = """
    SELECT 
        schemaname,
        tablename,
        n_tup_ins as inserts,
        n_tup_upd as updates,
        n_tup_del as deletes,
        seq_scan as sequential_scans,
        seq_tup_read as seq_rows_read,
        idx_scan as index_scans,
        idx_tup_fetch as idx_rows_fetched
    FROM pg_stat_user_tables 
    WHERE schemaname IN ('entsoe', 'simulations')
    ORDER BY seq_tup_read + idx_tup_fetch DESC
    LIMIT 10;
    """

    try
        df = sql2df(table_query)
        println("   📊 Most active tables:")
        for row in eachrow(df)
            total_reads = row.seq_rows_read + row.idx_rows_fetched
            if total_reads > 0
                println("      $(row.schemaname).$(row.tablename): $(total_reads) rows read")
            end
        end

    catch e
        println("   ❌ Error checking table activity: $e")
    end
end

# Function to monitor database during parallel processing
function monitor_during_parallel_processing(duration_seconds::Int=60)
    println("\n🔄 Monitoring database during parallel processing...")
    println("   Duration: $(duration_seconds) seconds")
    println("   Press Ctrl+C to stop early")
    println()

    start_time = time()

    try
        while (time() - start_time) < duration_seconds
            println("📊 $(round(time() - start_time, digits=0))s elapsed:")
            check_database_connections()
            check_database_performance()

            println("   ⏳ Waiting 10 seconds...")
            sleep(10)
        end
    catch InterruptException
        println("\n🛑 Monitoring stopped by user")
    end

    println("\n✅ Monitoring complete")
end

# Main monitoring menu
function main_menu()
    while true
        println("\n🗄️  DATABASE MONITORING MENU")
        println("="^40)
        println("1. Check current connections")
        println("2. Check performance metrics")
        println("3. Check ENTSO-E table activity")
        println("4. Monitor during parallel processing (60s)")
        println("5. Monitor during parallel processing (custom duration)")
        println("6. Exit")
        println()
        print("Choose option (1-6): ")

        choice = readline()

        if choice == "1"
            check_database_connections()
        elseif choice == "2"
            check_database_performance()
        elseif choice == "3"
            check_entsoe_table_activity()
        elseif choice == "4"
            monitor_during_parallel_processing(60)
        elseif choice == "5"
            print("Enter duration in seconds: ")
            try
                duration = parse(Int, readline())
                monitor_during_parallel_processing(duration)
            catch
                println("❌ Invalid duration")
            end
        elseif choice == "6"
            println("👋 Goodbye!")
            break
        else
            println("❌ Invalid choice. Please select 1-6.")
        end
    end
end

# Run initial check
check_database_connections()
check_database_performance()
check_entsoe_table_activity()

println("\n💡 TIP: Run this script in a separate terminal while testing parallel workers")
println("💡 TIP: Watch for connection count approaching the limit (usually 100-200)")
println("💡 TIP: Look for slow queries that might indicate database bottlenecks")

# Offer interactive menu
print("\nWould you like to start interactive monitoring? (y/n): ")
response = readline()
if lowercase(response) == "y" || lowercase(response) == "yes"
    main_menu()
end