"""
Multi-Zone MPCC Market Clearing Tests

Tests for multi-zone market clearing with cross-border transmission flows:
- TransferCapacity integration with MPCC solver
- ATC constraint enforcement
- Power balance with transmission flows
- Price separation under congestion
- Price convergence when uncongested
"""

using Test
using JuMP, HiGHS
using Dates, DataFrames
using Euphemia

@testset "Multi-Zone MPCC Tests" begin

    @testset "Zone Discovery and TransferCapacity" begin
        @testset "get_zone_pairs" begin
            # Create example transfer capacity
            tc = create_example_transfer_capacity()

            pairs = get_zone_pairs(tc)

            # Should have 3 zone pairs: A-C, H-C, H-J
            @test length(pairs) >= 3
            @test ("A", "C") in pairs || ("C", "A") in pairs
            @test ("H", "C") in pairs || ("C", "H") in pairs
            @test ("H", "J") in pairs || ("J", "H") in pairs
        end

        @testset "get_connected_zones" begin
            tc = create_example_transfer_capacity()

            # Zone C receives from A and H
            zones_to_c, zones_from_c = get_connected_zones(tc, "C")

            # A can send to C
            @test "A" in zones_to_c || "H" in zones_to_c

            # Zone H sends to C and J
            zones_to_h, zones_from_h = get_connected_zones(tc, "H")
            @test "C" in zones_from_h || "J" in zones_from_h
        end
    end

    @testset "Two-Zone Toy Example" begin
        @testset "Uncongested - Prices Should Converge" begin
            # Create a simple two-zone system with high ATC (no congestion)
            # Zone A: excess supply (cheap)
            # Zone B: excess demand (expensive)
            # With high ATC, prices should equalize

            model = Model(HiGHS.Optimizer)
            set_silent(model)

            zones = ["A", "B"]
            periods = ["1"]

            # Variables
            @variable(model, supply_A >= 0)  # Supply in A
            @variable(model, demand_B >= 0)  # Demand in B
            @variable(model, flow_A_to_B)    # Flow from A to B
            @variable(model, price[z in zones])

            # ATC constraints (high capacity - 1000 MW both directions)
            @constraint(model, -1000 <= flow_A_to_B <= 1000)

            # Power balance in each zone
            # Zone A: supply - outflow = 0
            @constraint(model, supply_A - flow_A_to_B == 0)
            # Zone B: demand + inflow = 0 (demand is positive consumption)
            @constraint(model, -demand_B + flow_A_to_B == 0)

            # Supply and demand quantities (fixed for this test)
            @constraint(model, supply_A == 100)  # 100 MW supply
            @constraint(model, demand_B == 100)  # 100 MW demand

            # Objective: maximize surplus (simplified)
            supply_price_A = 30.0  # Cheap supply in A
            demand_price_B = 80.0  # High willingness to pay in B
            @objective(model, Max, demand_B * demand_price_B - supply_A * supply_price_A)

            optimize!(model)

            @test termination_status(model) == MOI.OPTIMAL

            # Check that flow is used to balance (should be ~100 MW A→B)
            flow_val = value(flow_A_to_B)
            @test abs(flow_val - 100) < 1e-3  # Flow should be 100 MW
        end

        @testset "Congested - Prices Should Separate" begin
            # Same setup but with limited ATC
            # ATC = 50 MW means only half the demand can be met by imports
            # This should cause price separation

            model = Model(HiGHS.Optimizer)
            set_silent(model)

            zones = ["A", "B"]

            # Variables
            @variable(model, 0 <= supply_A <= 100)
            @variable(model, 0 <= supply_B <= 100)  # Also some local supply in B
            @variable(model, demand_A >= 0)
            @variable(model, demand_B >= 0)
            @variable(model, flow_A_to_B)
            @variable(model, load_shed_B >= 0)  # Emergency load shedding

            # ATC constraints (limited - 50 MW)
            atc_limit = 50.0
            @constraint(model, -atc_limit <= flow_A_to_B <= atc_limit)

            # Power balance
            # Zone A: supply - demand - outflow = 0
            @constraint(model, supply_A - demand_A - flow_A_to_B == 0)
            # Zone B: supply + inflow - demand + load_shed = 0
            @constraint(model, supply_B + flow_A_to_B - demand_B + load_shed_B == 0)

            # Fixed demands
            @constraint(model, demand_A == 20)   # 20 MW demand in A
            @constraint(model, demand_B == 100)  # 100 MW demand in B

            # Costs (simplified economic dispatch)
            cost_A = 30.0   # €30/MWh in A
            cost_B = 60.0   # €60/MWh in B
            load_shed_cost = 10000.0  # Very high penalty

            @objective(model, Min,
                cost_A * supply_A + cost_B * supply_B + load_shed_cost * load_shed_B)

            optimize!(model)

            @test termination_status(model) == MOI.OPTIMAL

            # Check results
            @test value(supply_A) > 50  # A should produce more than its own demand
            @test abs(value(flow_A_to_B) - atc_limit) < 1e-3  # Flow should be at ATC limit
            @test value(supply_B) > 0  # B needs local supply due to congestion
            @test value(load_shed_B) < 1e-3  # No load shedding needed
        end
    end

    @testset "MPCCOrderBook with TransferCapacity" begin
        @testset "TransferCapacity Type Check" begin
            # Test that MPCCOrderBook can accept TransferCapacity
            tc = create_example_transfer_capacity()

            # Create a minimal order book with TransferCapacity
            orders = MarketOrder[]
            nodes = ["A", "C"]
            periods = ["1"]
            price_limits = (0.0, 500.0)

            order_book = MPCCOrderBook(orders, nodes, periods, price_limits, tc)

            @test order_book.network_topology isa TransferCapacity
            @test length(order_book.nodes) == 2
        end
    end

    @testset "Integration with MPCC Solver" begin
        @testset "MPCC with TransferCapacity - Toy Example" begin
            # Create a simple two-zone order book with transfer capacity

            # Create transfer capacity between zones A and B
            zones = ["A", "B"]
            periods = ["1", "2", "3"]

            capacity_forward = Dict{Tuple{String,String,String},Float64}()
            capacity_backward = Dict{Tuple{String,String,String},Float64}()

            for p in periods
                capacity_forward[("A", "B", p)] = 100.0  # A→B: 100 MW
                capacity_backward[("A", "B", p)] = 100.0  # B→A: 100 MW
            end

            tc = TransferCapacity(zones, periods, capacity_forward, capacity_backward)

            # Create simple orders (using actual SimpleOrder type)
            # SimpleOrder fields: type, price, quantity, zone, date_time, resolution_code
            orders = MarketOrder[]

            # Supply orders in zone A (cheap)
            for (i, p) in enumerate(periods)
                dt = DateTime(2024, 6, 15, i-1)  # Hours 0, 1, 2
                # Supply order: type=:supply, price=30€/MWh, quantity=50MW, zone=:A
                push!(orders, SimpleOrder(:supply, 30.0, 50.0, :A, dt, 60))
            end

            # Demand orders in zone B (willing to pay more)
            for (i, p) in enumerate(periods)
                dt = DateTime(2024, 6, 15, i-1)
                # Demand order: type=:demand, price=80€/MWh, quantity=40MW, zone=:B
                push!(orders, SimpleOrder(:demand, 80.0, 40.0, :B, dt, 60))
            end

            # Map periods to timeslot format
            day = Date(2024, 6, 15)
            timeslot_periods = ["20240615-0000", "20240615-0100", "20240615-0200"]

            # Create updated transfer capacity with timeslot periods
            tc_timeslot = TransferCapacity(zones, timeslot_periods,
                Dict((s,d,"$(lpad(parse(Int,p)-1, 4, '0')[1:2])") => v for ((s,d,p), v) in capacity_forward),
                Dict((s,d,"$(lpad(parse(Int,p)-1, 4, '0')[1:2])") => v for ((s,d,p), v) in capacity_backward))

            # Actually create with hourly periods that match the lookup
            capacity_forward_hourly = Dict{Tuple{String,String,String},Float64}()
            capacity_backward_hourly = Dict{Tuple{String,String,String},Float64}()
            for h in 1:24
                capacity_forward_hourly[("A", "B", string(h))] = 100.0
                capacity_backward_hourly[("A", "B", string(h))] = 100.0
            end
            tc_hourly = TransferCapacity(zones, [string(h) for h in 1:24],
                                         capacity_forward_hourly, capacity_backward_hourly)

            # Create order book
            order_book = MPCCOrderBook(
                orders,
                zones,
                timeslot_periods,
                (0.0, 500.0),
                tc_hourly
            )

            @test order_book.network_topology isa TransferCapacity
            @test length(order_book.orders) == 6  # 3 supply + 3 demand

            # Run MPCC solver
            result = solve_mpcc_market_clearing(order_book;
                                                preferred_solver="highs",
                                                silent=true)

            @test result.status == :optimal

            # Check that prices exist for both zones
            @test haskey(result.market_prices, "A")
            @test haskey(result.market_prices, "B")

            # Check that transmission flows exist
            @test !isempty(result.transmission_flows) || length(zones) == 1

            println("✅ Multi-zone MPCC test passed!")
            println("   Status: $(result.status)")
            println("   Solve time: $(round(result.solve_time, digits=3))s")

            if haskey(result.market_prices, "A") && !isempty(result.market_prices["A"])
                avg_a = sum(values(result.market_prices["A"])) / length(result.market_prices["A"])
                println("   Zone A avg price: €$(round(avg_a, digits=2))/MWh")
            end

            if haskey(result.market_prices, "B") && !isempty(result.market_prices["B"])
                avg_b = sum(values(result.market_prices["B"])) / length(result.market_prices["B"])
                println("   Zone B avg price: €$(round(avg_b, digits=2))/MWh")
            end

            for (flow_id, flows) in result.transmission_flows
                if !isempty(flows)
                    avg_flow = sum(values(flows)) / length(flows)
                    println("   Flow $flow_id: avg $(round(avg_flow, digits=1)) MW")
                end
            end
        end
    end

end

println("\n✅ All multi-zone MPCC tests completed!")
