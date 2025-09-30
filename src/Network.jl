module Network

using JuMP, Dates, DataFrames

# Export both approaches
export NetworkTopology, TransferCapacity, create_example_network, add_atc_constraints!
export create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
export create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!
export create_example_transfer_capacity, create_greek_transfer_capacity_from_entsoe
export get_bidding_zones, get_outgoing_lines, get_incoming_lines

"""
Helper function to check if database functionality is available.
"""
function is_database_available()
    return isdefined(Main, :Euphemia) && isdefined(Main.Euphemia, :sql2df) && hasmethod(Main.Euphemia.sql2df, (String,))
end

"""
Helper function to safely call database query.
"""
function safe_sql2df(query::String)
    if !is_database_available()
        throw(ErrorException("Database function not available - Main.Euphemia.sql2df not found"))
    end
    return Main.Euphemia.sql2df(query)
end

# =============================================================================
# PHYSICAL NETWORK APPROACH (Line-based modeling)
# =============================================================================

"""
Network topology and constraints data structures for EUPHEMIA
Based on Section 4.3 (ATC Model) of the Euphemia Public Description
"""
struct NetworkTopology
    lines::Vector{String}                          # Line identifiers  
    time_periods::Vector{String}                   # Time period identifiers
    ATC_UP::Dict{Tuple{String,String},Float64}     # Upper ATC limits [line, period] → MW
    ATC_DOWN::Dict{Tuple{String,String},Float64}   # Lower ATC limits [line, period] → MW
    source_zone::Dict{String,String}               # Line → source bidding zone
    sink_zone::Dict{String,String}                 # Line → sink bidding zone
end

"""
    create_example_network()

Creates an example network topology based on Figure 2 from Section 4.3 (ATC Model).
Includes bidding zones A, C, H, J with interconnectors as shown in the documentation.
"""
function create_example_network()
    return NetworkTopology(
        # Line identifiers (source→sink naming convention)
        ["A_to_C", "H_to_C", "H_to_J"],

        # Time periods (would typically be 24 hourly periods for day-ahead)
        ["1", "2", "3"],

        # ATC_UP: Upper limits for each [line, time_period] (MW)
        Dict(
            ("A_to_C", "1") => 250.0, ("A_to_C", "2") => 250.0, ("A_to_C", "3") => 250.0,
            ("H_to_C", "1") => 600.0, ("H_to_C", "2") => 600.0, ("H_to_C", "3") => 600.0,
            ("H_to_J", "1") => 1600.0, ("H_to_J", "2") => 1600.0, ("H_to_J", "3") => 1600.0
        ),

        # ATC_DOWN: Lower limits for each [line, time_period] (MW, negative values)
        Dict(
            ("A_to_C", "1") => -300.0, ("A_to_C", "2") => -300.0, ("A_to_C", "3") => -300.0,
            ("H_to_C", "1") => -500.0, ("H_to_C", "2") => -500.0, ("H_to_C", "3") => -500.0,
            ("H_to_J", "1") => -900.0, ("H_to_J", "2") => -900.0, ("H_to_J", "3") => -900.0
        ),

        # Source bidding zone for each line
        Dict("A_to_C" => "A", "H_to_C" => "H", "H_to_J" => "H"),

        # Sink bidding zone for each line  
        Dict("A_to_C" => "C", "H_to_C" => "C", "H_to_J" => "J")
    )
end

"""
    add_atc_constraints!(model::Model, network::NetworkTopology, FLOW)

Adds ATC (Available Transfer Capacity) constraints to a JuMP model.
Based on Section 4.3.1 of the Euphemia Public Description.

# Arguments
- `model::Model`: JuMP optimization model
- `network::NetworkTopology`: Network topology data
- `FLOW`: JuMP variable array for line flows [line, time_period]

# Constraints Added
For each line l and time period t:
```
ATC_DOWN[l, t] ≤ FLOW[l, t] ≤ ATC_UP[l, t]
```

# Flow Convention
- Positive flow: source zone → sink zone
- Negative flow: sink zone → source zone
- ATC_UP: limit in line direction (positive flows)
- ATC_DOWN: limit in reverse direction (negative flows, stored as negative values)

# Examples
From documentation Section 4.3.1:
- Line A→C with ATC_UP=250, ATC_DOWN=-300: flow ∈ [-300, 250]
- Negative ATC forces flow direction (e.g., ATC_UP=-250: flow ∈ [-300, -250])
"""
function add_atc_constraints!(model::Model, network::NetworkTopology, FLOW)
    lines = network.lines
    time_periods = network.time_periods
    ATC_UP = network.ATC_UP
    ATC_DOWN = network.ATC_DOWN

    # ATC Constraints (Section 4.3.1)
    # For each line l and time period t, flow must be within ATC limits
    @constraint(model, atc_constraints[l in lines, t in time_periods],
        ATC_DOWN[l, t] <= FLOW[l, t] <= ATC_UP[l, t]
    )

    return model
end

# =============================================================================
# TRANSFER CAPACITY APPROACH (Zone-based modeling) - RECOMMENDED FOR ENTSO-E
# =============================================================================

"""
Transfer capacity data structure for market clearing between bidding zones.
This represents the available transfer capacity between bidding zones without 
needing to model individual transmission lines.
"""
struct TransferCapacity
    bidding_zones::Vector{String}                   # All bidding zones in the system
    time_periods::Vector{String}                    # Time period identifiers
    # Positive capacity: from source_zone → sink_zone
    capacity_forward::Dict{Tuple{String,String,String},Float64}  # [source, sink, period] → MW
    # Negative capacity: from sink_zone → source_zone (stored as positive values)
    capacity_backward::Dict{Tuple{String,String,String},Float64} # [source, sink, period] → MW
end

"""
    add_transfer_capacity_constraints!(model::Model, transfer_capacity::TransferCapacity, FLOW)

Adds transfer capacity constraints to a JuMP model for bidding zone transfers.

# Arguments
- `model::Model`: JuMP optimization model
- `transfer_capacity::TransferCapacity`: Transfer capacity data between bidding zones
- `FLOW`: JuMP variable array for flows between zones [source_zone, sink_zone, time_period]

# Constraints Added
For each bidding zone pair (source, sink) and time period t:
```
-capacity_backward[source, sink, t] ≤ FLOW[source, sink, t] ≤ capacity_forward[source, sink, t]
```

# Flow Convention
- Positive FLOW[source, sink, t]: transfer from source → sink
- Negative FLOW[source, sink, t]: transfer from sink → source
- capacity_forward: maximum transfer source → sink
- capacity_backward: maximum transfer sink → source (stored as positive)
"""
function add_transfer_capacity_constraints!(model::Model, transfer_capacity::TransferCapacity, FLOW)
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods
    capacity_forward = transfer_capacity.capacity_forward
    capacity_backward = transfer_capacity.capacity_backward

    # Transfer capacity constraints for all zone pairs
    @constraint(model, transfer_capacity_constraints[source in zones, sink in zones, t in time_periods; source != sink],
        -get(capacity_backward, (source, sink, t), 0.0) <= FLOW[source, sink, t] <= get(capacity_forward, (source, sink, t), 0.0)
    )

    return model
end

"""
    create_example_transfer_capacity()

Creates an example TransferCapacity structure for testing.
Based on the same bidding zones as the example network.
"""
function create_example_transfer_capacity()
    zones = ["A", "C", "H", "J"]
    periods = ["1", "2", "3"]

    capacity_forward = Dict{Tuple{String,String,String},Float64}()
    capacity_backward = Dict{Tuple{String,String,String},Float64}()

    # A ↔ C interconnection
    for period in periods
        capacity_forward[("A", "C", period)] = 250.0   # A → C
        capacity_backward[("A", "C", period)] = 300.0  # C → A
    end

    # H ↔ C interconnection  
    for period in periods
        capacity_forward[("H", "C", period)] = 600.0   # H → C
        capacity_backward[("H", "C", period)] = 500.0  # C → H
    end

    # H ↔ J interconnection
    for period in periods
        capacity_forward[("H", "J", period)] = 1600.0  # H → J
        capacity_backward[("H", "J", period)] = 900.0  # J → H
    end

    return TransferCapacity(zones, periods, capacity_forward, capacity_backward)
end

# =============================================================================
# ENTSO-E DATA INTEGRATION (Both approaches support real data)
# =============================================================================

"""
    create_transfer_capacity_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Creates a TransferCapacity structure using real ENTSO-E data.
More suitable for market clearing applications than NetworkTopology.

# Arguments
- `date::Date`: The date for which to retrieve transfer capacities
- `bidding_zones::Vector{String}`: Optional filter for specific bidding zones (empty = all zones)

# Returns
- `TransferCapacity`: Transfer capacity data between bidding zones
"""
function create_transfer_capacity_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])
    try
        # Build SQL query to get transfer capacities for the specified date
        zone_filter = isempty(bidding_zones) ? "" :
                      "AND (out_area_code IN ('" * join(bidding_zones, "','") * "') OR in_area_code IN ('" * join(bidding_zones, "','") * "'))"

        query = """
        SELECT 
            out_area_code as source_zone,
            in_area_code as sink_zone,
            EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
            capacity_mw as capacity
        FROM entsoe.offered_transfer_capacities_implicit 
        WHERE DATE(date_time_utc) = '$date'
        $zone_filter
        ORDER BY out_area_code, in_area_code, date_time_utc
        """

        println("📊 Fetching ENTSO-E transfer capacity data for $date...")
        df = safe_sql2df(query)

        if nrow(df) == 0
            @warn "No ENTSO-E transfer capacity data found for $date"
            return create_example_transfer_capacity()  # Fallback to example
        end

        println("✅ Found $(nrow(df)) transfer capacity records")
        return build_transfer_capacity_from_dataframe(df)

    catch e
        @error "Failed to fetch ENTSO-E transfer capacity data: $e"
        @warn "Falling back to example transfer capacity"
        return create_example_transfer_capacity()
    end
end

"""
    build_transfer_capacity_from_dataframe(df::DataFrame)

Converts ENTSO-E transfer capacity DataFrame into TransferCapacity structure.
"""
function build_transfer_capacity_from_dataframe(df::DataFrame)
    zones = Set{String}()
    time_periods = Set{String}()
    capacity_forward = Dict{Tuple{String,String,String},Float64}()
    capacity_backward = Dict{Tuple{String,String,String},Float64}()

    for row in eachrow(df)
        source = row.source_zone
        sink = row.sink_zone
        period = string(Int(row.time_period))
        capacity = row.capacity

        # Collect unique zones and time periods
        push!(zones, source, sink)
        push!(time_periods, period)

        # Store forward capacity
        capacity_forward[(source, sink, period)] = capacity

        # Initialize backward capacity to 0 if not already set
        if !haskey(capacity_backward, (source, sink, period))
            capacity_backward[(source, sink, period)] = 0.0
        end
    end

    # Convert to sorted vectors
    zones_vec = sort(collect(zones))
    periods_vec = sort(collect(time_periods), by=x -> parse(Int, x))

    println("✅ Created transfer capacity structure:")
    println("   🌍 Bidding zones: $(length(zones_vec)) ($(join(zones_vec, ", ")))")
    println("   🕐 Time periods: $(length(periods_vec))")
    println("   ➡️  Forward capacities: $(count(v -> v > 0, values(capacity_forward)))")
    println("   ⬅️  Backward capacities: $(count(v -> v > 0, values(capacity_backward)))")

    return TransferCapacity(
        zones_vec,
        periods_vec,
        capacity_forward,
        capacity_backward
    )
end

"""
    create_greek_transfer_capacity_from_entsoe(date::Date)

Creates a TransferCapacity focused on Greek (GR) interconnections using real ENTSO-E data.
Includes connections to neighboring countries (BG, IT, AL, MK, TR).
"""
function create_greek_transfer_capacity_from_entsoe(date::Date)
    # Greek neighboring zones based on typical interconnections
    greek_zones = ["GR", "BG", "IT", "AL", "MK", "TR"]
    return create_transfer_capacity_from_entsoe(date, greek_zones)
end

"""
    get_entsoe_transfer_capacities(date::Date, source_zone::String, sink_zone::String)

Retrieves specific transfer capacity data for a bidding zone pair on a given date.

# Returns
- `DataFrame`: Hourly transfer capacities with columns: hour, capacity_forward, capacity_backward
"""
function get_entsoe_transfer_capacities(date::Date, source_zone::String, sink_zone::String)
    try
        query = """
        SELECT 
            EXTRACT(HOUR FROM date_time_utc) + 1 as hour,
            capacity_mw as capacity_forward,
            0.0 as capacity_backward
        FROM entsoe.offered_transfer_capacities_implicit 
        WHERE DATE(date_time_utc) = '$date'
          AND out_area_code = '$source_zone'  
          AND in_area_code = '$sink_zone'
        ORDER BY hour
        """

        return safe_sql2df(query)
    catch e
        @error "Failed to fetch transfer capacity data for $source_zone → $sink_zone on $date: $e"
        return DataFrame(hour=Int[], capacity_forward=Float64[], capacity_backward=Float64[])
    end
end

# =============================================================================
# COMMON UTILITY FUNCTIONS
# =============================================================================

"""
    get_bidding_zones(network::NetworkTopology)

Returns the set of all bidding zones in the network topology.
"""
function get_bidding_zones(network::NetworkTopology)
    zones = Set{String}()
    for zone in values(network.source_zone)
        push!(zones, zone)
    end
    for zone in values(network.sink_zone)
        push!(zones, zone)
    end
    return collect(zones)
end

"""
    get_bidding_zones(transfer_capacity::TransferCapacity)

Returns the set of all bidding zones in the transfer capacity structure.
"""
function get_bidding_zones(transfer_capacity::TransferCapacity)
    return transfer_capacity.bidding_zones
end

"""
    get_outgoing_lines(network::NetworkTopology, zone::String)

Returns lines originating from the specified bidding zone.
"""
function get_outgoing_lines(network::NetworkTopology, zone::String)
    return [line for (line, source) in network.source_zone if source == zone]
end

"""
    get_incoming_lines(network::NetworkTopology, zone::String)

Returns lines terminating at the specified bidding zone.
"""
function get_incoming_lines(network::NetworkTopology, zone::String)
    return [line for (line, sink) in network.sink_zone if sink == zone]
end

# =============================================================================
# LEGACY SUPPORT FOR PHYSICAL NETWORK APPROACH
# =============================================================================

"""
    create_network_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Creates a NetworkTopology using real ENTSO-E transfer capacity data from the database.
Note: This approach is less suitable for ENTSO-E data than TransferCapacity.
"""
function create_network_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])
    try
        # Build SQL query to get transfer capacities for the specified date
        zone_filter = isempty(bidding_zones) ? "" :
                      "AND (out_area_code IN ('" * join(bidding_zones, "','") * "') OR in_area_code IN ('" * join(bidding_zones, "','") * "'))"

        query = """
        SELECT 
            out_area_code as source_zone,
            in_area_code as sink_zone,
            EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
            capacity_mw as capacity
        FROM entsoe.offered_transfer_capacities_implicit 
        WHERE DATE(date_time_utc) = '$date'
        $zone_filter
        ORDER BY out_area_code, in_area_code, date_time_utc
        """

        println("📊 Fetching ENTSO-E transfer capacity data for $date...")
        df = safe_sql2df(query)

        if nrow(df) == 0
            @warn "No ENTSO-E transfer capacity data found for $date"
            return create_example_network()  # Fallback to example
        end

        println("✅ Found $(nrow(df)) transfer capacity records")
        return build_network_from_dataframe(df)

    catch e
        @error "Failed to fetch ENTSO-E transfer capacity data: $e"
        @warn "Falling back to example network"
        return create_example_network()
    end
end

"""
    build_network_from_dataframe(df::DataFrame)

Converts ENTSO-E transfer capacity DataFrame into NetworkTopology structure.
"""
function build_network_from_dataframe(df::DataFrame)
    # Extract unique bidding zone pairs and time periods
    lines = String[]
    time_periods = String[]
    ATC_UP = Dict{Tuple{String,String},Float64}()
    ATC_DOWN = Dict{Tuple{String,String},Float64}()
    source_zone = Dict{String,String}()
    sink_zone = Dict{String,String}()

    for row in eachrow(df)
        source = row.source_zone
        sink = row.sink_zone
        period = string(Int(row.time_period))
        capacity = row.capacity

        # Create line identifier
        line_id = "$(source)_to_$(sink)"

        # Add to collections if not already present
        if !(line_id in lines)
            push!(lines, line_id)
            source_zone[line_id] = source
            sink_zone[line_id] = sink
        end

        if !(period in time_periods)
            push!(time_periods, period)
        end

        # Since ENTSO-E data represents directional capacity (source→sink),
        # we store it as ATC_UP (positive direction) and set ATC_DOWN to 0
        # For bidirectional capacity, there would be separate records for each direction
        ATC_UP[(line_id, period)] = capacity
        ATC_DOWN[(line_id, period)] = 0.0  # No reverse capacity unless explicitly defined
    end

    # Fill missing values with zero capacity
    for line in lines, period in time_periods
        if !haskey(ATC_UP, (line, period))
            ATC_UP[(line, period)] = 0.0
        end
        if !haskey(ATC_DOWN, (line, period))
            ATC_DOWN[(line, period)] = 0.0
        end
    end

    # Sort time periods numerically
    time_periods = sort(time_periods, by=x -> parse(Int, x))

    println("✅ Created network topology:")
    println("   📊 Lines: $(length(lines))")
    println("   🕐 Time periods: $(length(time_periods))")
    println("   🔌 ATC_UP entries: $(count(v -> v > 0, values(ATC_UP)))")
    println("   🔌 ATC_DOWN entries: $(count(v -> v < 0, values(ATC_DOWN)))")

    return NetworkTopology(
        lines,
        time_periods,
        ATC_UP,
        ATC_DOWN,
        source_zone,
        sink_zone
    )
end

"""
    create_greek_network_from_entsoe(date::Date)

Creates a NetworkTopology focused on Greek (GR) interconnections using real ENTSO-E data.
Includes connections to neighboring countries (BG, IT, AL, MK, TR).
"""
function create_greek_network_from_entsoe(date::Date)
    # Greek neighboring zones based on typical interconnections
    greek_zones = ["GR", "BG", "IT", "AL", "MK", "TR"]
    return create_network_from_entsoe(date, greek_zones)
end

"""
    Network Module Documentation

This module provides two approaches for modeling electricity network constraints:

## 1. TransferCapacity (Zone-based modeling) - RECOMMENDED
- Models transfer capacity between bidding zones
- Perfect alignment with ENTSO-E data structure
- Used by default in main Euphemia algorithm
- Best for: Market clearing, ENTSO-E data integration

## 2. NetworkTopology (Line-based modeling) - LEGACY
- Models individual transmission lines
- Forced abstraction of zone-level data
- Best for: Detailed transmission analysis, academic studies

## Usage Examples

### Recommended: TransferCapacity Approach
```julia
using .Network
transfer_cap = create_transfer_capacity_from_entsoe(Date("2025-01-01"))
model = Model()
zones = transfer_cap.bidding_zones
periods = transfer_cap.time_periods
@variable(model, TRANSFER_FLOW[s in zones, d in zones, t in periods; s != d])
add_transfer_capacity_constraints!(model, transfer_cap, TRANSFER_FLOW)
```

### Legacy: Physical Network Approach
```julia
using .Network
network = create_example_network()
model = Model()
@variable(model, FLOW[l in network.lines, t in network.time_periods])
add_atc_constraints!(model, network, FLOW)
```
"""

end # module Network