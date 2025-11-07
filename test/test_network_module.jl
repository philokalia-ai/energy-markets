"""
Network Module Tests

Tests for Network.jl module including:
- NetworkTopology structure and functions
- TransferCapacity structure and functions  
- ENTSO-E data integration
- JuMP constraint integration
"""

using Test
using JuMP, HiGHS
using Dates, DataFrames
using Euphemia

@testset "Network Module Tests" begin

    @testset "NetworkTopology Tests" begin
        @testset "Example Network Creation" begin
            network = create_example_network()

            @test isa(network, NetworkTopology)
            @test length(network.lines) == 3
            @test length(network.time_periods) == 3
            @test haskey(network.source_zone, "A_to_C")
            @test network.source_zone["A_to_C"] == "A"
            @test network.sink_zone["A_to_C"] == "C"

            # Test ATC values
            @test network.ATC_UP[("A_to_C", "1")] == 250.0
            @test network.ATC_DOWN[("A_to_C", "1")] == -300.0
        end

        @testset "Helper Functions" begin
            network = create_example_network()

            # Test get_bidding_zones
            zones = get_bidding_zones(network)
            @test "A" in zones
            @test "C" in zones
            @test "H" in zones
            @test "J" in zones
            @test length(zones) == 4

            # Test get_outgoing_lines
            outgoing_h = get_outgoing_lines(network, "H")
            @test "H_to_C" in outgoing_h
            @test "H_to_J" in outgoing_h
            @test length(outgoing_h) == 2

            # Test get_incoming_lines
            incoming_c = get_incoming_lines(network, "C")
            @test "A_to_C" in incoming_c
            @test "H_to_C" in incoming_c
            @test length(incoming_c) == 2
        end

        @testset "ATC Constraints Integration" begin
            network = create_example_network()
            model = Model(HiGHS.Optimizer)
            set_silent(model)

            # Create flow variables
            @variable(model, FLOW[line in network.lines, t in network.time_periods])

            # Add ATC constraints
            add_atc_constraints!(model, network, FLOW)

            # Test constraint creation
            @test num_constraints(model, AffExpr, MOI.Interval{Float64}) == length(network.lines) * length(network.time_periods)

            # Test a simple optimization
            @objective(model, Min, sum(FLOW))
            optimize!(model)

            @test termination_status(model) == MOI.OPTIMAL

            # Test that flows respect ATC bounds
            for line in network.lines, t in network.time_periods
                flow_value = value(FLOW[line, t])
                @test flow_value >= network.ATC_DOWN[(line, t)]
                @test flow_value <= network.ATC_UP[(line, t)]
            end
        end
    end

    @testset "TransferCapacity Tests" begin
        @testset "Example Transfer Capacity Creation" begin
            transfer_cap = create_example_transfer_capacity()

            @test isa(transfer_cap, TransferCapacity)
            @test length(transfer_cap.bidding_zones) == 4
            @test length(transfer_cap.time_periods) == 3
            @test "A" in transfer_cap.bidding_zones
            @test "C" in transfer_cap.bidding_zones
            @test "H" in transfer_cap.bidding_zones
            @test "J" in transfer_cap.bidding_zones

            # Test capacity values
            @test transfer_cap.capacity_forward[("A", "C", "1")] == 250.0
            @test transfer_cap.capacity_backward[("A", "C", "1")] == 300.0
        end

        @testset "Helper Functions" begin
            transfer_cap = create_example_transfer_capacity()

            # Test get_bidding_zones for TransferCapacity
            zones = get_bidding_zones(transfer_cap)
            @test length(zones) == 4
            @test "A" in zones
            @test "C" in zones
            @test "H" in zones
            @test "J" in zones
        end

        @testset "Transfer Capacity Constraints Integration" begin
            transfer_cap = create_example_transfer_capacity()
            model = Model(HiGHS.Optimizer)
            set_silent(model)

            zones = transfer_cap.bidding_zones
            periods = transfer_cap.time_periods

            # Create transfer flow variables
            @variable(model, TRANSFER_FLOW[source in zones, sink in zones, t in periods; source != sink])

            # Add transfer capacity constraints
            add_transfer_capacity_constraints!(model, transfer_cap, TRANSFER_FLOW)

            # Test constraint creation (should have constraints for zone pairs with capacity)
            constraint_count = 0
            for source in zones, sink in zones, t in periods
                if source != sink
                    constraint_count += 1
                end
            end

            @test num_constraints(model, AffExpr, MOI.Interval{Float64}) == constraint_count

            # Test a simple optimization
            @objective(model, Min, sum(TRANSFER_FLOW))
            optimize!(model)

            @test termination_status(model) == MOI.OPTIMAL

            # Test that transfers respect capacity bounds
            for source in zones, sink in zones, t in periods
                if source != sink
                    transfer_value = value(TRANSFER_FLOW[source, sink, t])
                    forward_cap = get(transfer_cap.capacity_forward, (source, sink, t), 0.0)
                    backward_cap = get(transfer_cap.capacity_backward, (source, sink, t), 0.0)

                    @test transfer_value <= forward_cap
                    @test transfer_value >= -backward_cap
                end
            end
        end
    end

    @testset "ENTSO-E Data Integration Tests" begin
        @testset "Database Functions (if available)" begin
            test_date = Date("2025-06-27")

            # Test create_network_from_entsoe (may fallback to example due to no database)
            network = create_network_from_entsoe(test_date)
            @test isa(network, NetworkTopology)
            # Should fallback to example network when database not available
            @test length(network.lines) >= 1

            # Test create_greek_network_from_entsoe (may fallback to example due to no database)
            greek_network = create_greek_network_from_entsoe(test_date)
            @test isa(greek_network, NetworkTopology)
            @test length(greek_network.lines) >= 1

            # Test create_transfer_capacity_from_entsoe (may fallback to example due to no database)
            transfer_cap = create_transfer_capacity_from_entsoe(test_date)
            @test isa(transfer_cap, TransferCapacity)
            @test length(transfer_cap.bidding_zones) >= 1

            # Test get_entsoe_transfer_capacities (returns DataFrame, may be empty due to no database)
            capacities_df = get_entsoe_transfer_capacities(test_date, "GR", "IT")
            @test isa(capacities_df, DataFrame)
            # Should have correct columns even if empty
            @test "hour" in names(capacities_df) || nrow(capacities_df) == 0
        end

        @testset "Fallback Mechanism" begin
            # Test with a future date that definitely won't have data
            future_date = Date("2030-01-01")

            network = create_network_from_entsoe(future_date)
            @test isa(network, NetworkTopology)
            @test length(network.lines) == 3  # Should fallback to example network

            transfer_cap = create_transfer_capacity_from_entsoe(future_date)
            @test isa(transfer_cap, TransferCapacity)
            @test length(transfer_cap.bidding_zones) == 4  # Should fallback to example
        end
    end

    @testset "Integration Tests" begin
        @testset "NetworkTopology to TransferCapacity Consistency" begin
            # Both example functions should create compatible zone structures
            network = create_example_network()
            transfer_cap = create_example_transfer_capacity()

            network_zones = Set(get_bidding_zones(network))
            transfer_zones = Set(get_bidding_zones(transfer_cap))

            @test network_zones == transfer_zones
        end

        @testset "Constraint Compatibility" begin
            # Test that both constraint types can be used in the same model
            network = create_example_network()
            transfer_cap = create_example_transfer_capacity()

            model = Model(HiGHS.Optimizer)
            set_silent(model)

            # Add variables for both types
            @variable(model, LINE_FLOW[line in network.lines, t in network.time_periods])
            zones = transfer_cap.bidding_zones
            periods = transfer_cap.time_periods
            @variable(model, ZONE_FLOW[source in zones, sink in zones, t in periods; source != sink])

            # Add both types of constraints
            add_atc_constraints!(model, network, LINE_FLOW)
            add_transfer_capacity_constraints!(model, transfer_cap, ZONE_FLOW)

            # Simple objective
            @objective(model, Min, sum(LINE_FLOW) + sum(ZONE_FLOW))

            # Should optimize successfully
            optimize!(model)
            @test termination_status(model) == MOI.OPTIMAL
        end
    end
end

println("✅ Network module tests completed successfully!")