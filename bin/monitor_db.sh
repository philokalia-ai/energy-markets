#!/bin/bash
# Database monitoring commands for PostgreSQL

echo "🗄️  POSTGRESQL MONITORING COMMANDS"
echo "================================="

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "❌ psql not found. Please install postgresql-client:"
    echo "   sudo apt install postgresql-client"
    exit 1
fi

# Database connection info (modify as needed)
DB_HOST=${POSTGRES_HOST:-localhost}
DB_PORT=${POSTGRES_PORT:-5432}
DB_NAME=${POSTGRES_DB:-entsoe}
DB_USER=${POSTGRES_USER:-postgres}

echo "📊 Database: $DB_NAME on $DB_HOST:$DB_PORT as $DB_USER"
echo ""

# Function to run a query
run_query() {
    local query="$1"
    local description="$2"
    
    echo "🔍 $description"
    echo "----------------------------------------"
    psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -c "$query" 2>/dev/null || echo "❌ Query failed"
    echo ""
}

# Check current connections
run_query "
SELECT 
    state, 
    COUNT(*) as connections,
    string_agg(DISTINCT application_name, ', ') as apps
FROM pg_stat_activity 
WHERE pid != pg_backend_pid()
GROUP BY state
ORDER BY connections DESC;
" "Current Database Connections"

# Check connection limit and usage
run_query "
SELECT 
    setting as max_connections,
    (SELECT COUNT(*) FROM pg_stat_activity) as current_connections,
    ROUND(
        (SELECT COUNT(*) FROM pg_stat_activity)::float / setting::float * 100, 
        1
    ) as usage_percentage
FROM pg_settings 
WHERE name = 'max_connections';
" "Connection Usage vs Limit"

# Check for long-running queries
run_query "
SELECT 
    pid,
    state,
    EXTRACT(epoch FROM (now() - query_start))::int as duration_seconds,
    LEFT(query, 80) as query_preview
FROM pg_stat_activity 
WHERE state = 'active' 
  AND query_start < now() - interval '5 seconds'
  AND pid != pg_backend_pid()
ORDER BY duration_seconds DESC
LIMIT 10;
" "Long-Running Queries (>5s)"

# Check locks
run_query "
SELECT 
    mode,
    COUNT(*) as lock_count
FROM pg_locks 
GROUP BY mode
ORDER BY lock_count DESC;
" "Database Locks by Type"

# Check table activity
run_query "
SELECT 
    schemaname || '.' || tablename as table_name,
    seq_scan + idx_scan as total_scans,
    seq_tup_read + idx_tup_fetch as total_reads
FROM pg_stat_user_tables 
WHERE schemaname IN ('entsoe', 'simulations')
  AND (seq_tup_read + idx_tup_fetch) > 0
ORDER BY total_reads DESC
LIMIT 10;
" "Most Active Tables"

echo "💡 MONITORING TIPS:"
echo "• Run this script while testing parallel workers"
echo "• Watch connection count - shouldn't exceed 80% of max"
echo "• Long-running queries indicate potential bottlenecks"
echo "• High lock counts suggest contention issues"
echo ""
echo "🔄 To monitor continuously, run:"
echo "   watch -n 5 ./monitor_db.sh"