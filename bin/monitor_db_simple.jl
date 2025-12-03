#!/usr/bin/env julia
# Simple database monitoring for parallel workers

using Euphemia
using DataFrames

println("🗄️  DATABASE CONNECTION MONITOR")
println("="^50)

try
    # Check current connections
    println("\n📊 Current Database Connections:")
    conn_query = """
    SELECT 
        state,
        COUNT(*) as count,
        string_agg(DISTINCT application_name, ', ') as apps
    FROM pg_stat_activity 
    WHERE pid != pg_backend_pid()
    GROUP BY state
    ORDER BY count DESC;
    """

    df = Euphemia.sql2df(conn_query)
    for row in eachrow(df)
        println("   $(row.state): $(row.count) connections")
    end

    # Check total vs max
    println("\n🚨 Connection Limits:")
    total_query = """
    SELECT 
        (SELECT COUNT(*) FROM pg_stat_activity) as current,
        (SELECT setting::int FROM pg_settings WHERE name='max_connections') as max_allowed
    """

    limits_df = Euphemia.sql2df(total_query)
    current = limits_df.current[1]
    max_allowed = limits_df.max_allowed[1]
    usage = round(current / max_allowed * 100, digits=1)

    println("   Current: $current")
    println("   Maximum: $max_allowed")
    println("   Usage: $usage%")

    if usage > 80
        println("   ⚠️  WARNING: High usage!")
    elseif usage > 60
        println("   💡 Caution: Monitor closely")
    else
        println("   ✅ Usage looks healthy")
    end

    # Check for slow queries
    println("\n🐌 Slow Queries (>5s):")
    slow_query = """
    SELECT 
        pid,
        ROUND(EXTRACT(epoch FROM (now() - query_start))) as duration_sec,
        LEFT(query, 60) as query_preview
    FROM pg_stat_activity 
    WHERE state = 'active' 
      AND query_start < now() - interval '5 seconds'
      AND pid != pg_backend_pid()
    ORDER BY duration_sec DESC;
    """

    slow_df = Euphemia.sql2df(slow_query)
    if nrow(slow_df) > 0
        for row in eachrow(slow_df)
            println("   $(row.duration_sec)s: $(row.query_preview)...")
        end
    else
        println("   ✅ No slow queries")
    end

catch e
    println("❌ Error connecting to database: $e")
    println("💡 Make sure your database environment variables are set correctly")
end

println("\n💡 USAGE TIPS:")
println("• Run this while testing parallel workers:")
println("  watch -n 5 'julia --project=. monitor_simple.jl'")
println("• Watch for connection usage approaching 80%")
println("• Reduce workers if you see many slow queries")
println("• Your 80-core machine can handle more workers than your database!")