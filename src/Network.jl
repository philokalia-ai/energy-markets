module Network

using JuMP

export NetworkTopology, create_example_network, add_atc_constraints!

"""
Network topology and constraints data structures for EUPHEMIA
Based on Section 4.3 (ATC Model) of the Euphemia Public Description
"""
struct NetworkTopology
    lines::Vector{String}                           # Line identifiers  
    time_periods::Vector{String}                    # Time period identifiers
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

        # ATC_UP: Maximum capacity in line direction (source→sink)
        Dict(
            ("A_to_C", "1") => 250.0,    # A→C: 250 MW limit
            ("A_to_C", "2") => 250.0,
            ("A_to_C", "3") => 250.0,
            ("H_to_C", "1") => 600.0,    # H→C: 600 MW limit  
            ("H_to_C", "2") => 600.0,
            ("H_to_C", "3") => 600.0,
            ("H_to_J", "1") => 1600.0,   # H→J: 1600 MW limit
            ("H_to_J", "2") => 1600.0,
            ("H_to_J", "3") => 1600.0
        ),

        # ATC_DOWN: Maximum capacity in reverse direction (sink→source, negative values)
        Dict(
            ("A_to_C", "1") => -300.0,   # C→A: 300 MW limit (negative)
            ("A_to_C", "2") => -300.0,
            ("A_to_C", "3") => -300.0,
            ("H_to_C", "1") => -500.0,   # C→H: 500 MW limit (negative)
            ("H_to_C", "2") => -500.0,
            ("H_to_C", "3") => -500.0,
            ("H_to_J", "1") => -900.0,   # J→H: 900 MW limit (negative)
            ("H_to_J", "2") => -900.0,
            ("H_to_J", "3") => -900.0
        ),

        # Source bidding zones for each line
        Dict(
            "A_to_C" => "A",
            "H_to_C" => "H",
            "H_to_J" => "H"
        ),

        # Sink bidding zones for each line
        Dict(
            "A_to_C" => "C",
            "H_to_C" => "C",
            "H_to_J" => "J"
        )
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
    get_outgoing_lines(network::NetworkTopology, zone::String)

Returns lines that have the given zone as source (outgoing flows are positive).
"""
function get_outgoing_lines(network::NetworkTopology, zone::String)
    return [line for (line, source) in network.source_zone if source == zone]
end

"""
    get_incoming_lines(network::NetworkTopology, zone::String)

Returns lines that have the given zone as sink (incoming flows are positive).
"""
function get_incoming_lines(network::NetworkTopology, zone::String)
    return [line for (line, sink) in network.sink_zone if sink == zone]
end

end # module Network
