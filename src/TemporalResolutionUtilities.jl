
# ==== Temporal Resolution Utilities ====
"""
Convert ENTSO-E resolution code (e.g., "PT15M", "PT60M") to minutes.
"""
function parse_resolution_to_minutes(resolution_code::String)::Int
    # Handle standard ENTSO-E ISO 8601 duration format: PT<number>M
    if startswith(resolution_code, "PT") && endswith(resolution_code, "M")
        minutes_str = resolution_code[3:end-1]
        try
            return parse(Int, minutes_str)
        catch
            @warn "Failed to parse resolution code: $resolution_code, defaulting to 60 minutes"
            return 60
        end
    else
        @warn "Unknown resolution code format: $resolution_code, defaulting to 60 minutes"
        return 60
    end
end

"""
Determine the finest (smallest) temporal resolution from multiple data sources.
Returns the target resolution in minutes and a summary of all found resolutions.
"""
function determine_finest_resolution(data_sources...)
    resolutions = String[]

    # Collect resolution codes from all data sources
    for data in data_sources
        if !isempty(data)
            # Handle different data structures
            if hasfield(typeof(data[1]), :resolution_code)
                # Standard format (loads, etc.)
                unique_resolutions = unique([d.resolution_code for d in data])
                append!(resolutions, unique_resolutions)
            elseif hasfield(typeof(data[1]), :temporal_resolution)
                # Alternative format
                unique_resolutions = unique([d.temporal_resolution for d in data])
                append!(resolutions, unique_resolutions)
            end
        end
    end

    if isempty(resolutions)
        @warn "No resolution codes found, defaulting to 60 minutes"
        return 60, ["PT60M"]
    end

    # Convert to minutes and find the finest (minimum)
    resolution_minutes = [parse_resolution_to_minutes(res) for res in resolutions]
    finest_minutes = minimum(resolution_minutes)

    return finest_minutes, resolutions
end

"""
Generate time slots at target resolution based on coarser source data.
"""
function generate_sub_slots_from_source(source_slots::Vector{String}, source_resolution::Int, target_resolution::Int)
    if source_resolution <= target_resolution
        return source_slots  # Already at finer or equal resolution
    end

    slots = String[]
    slots_per_source = source_resolution ÷ target_resolution

    for source_slot in source_slots
        # Parse the source timeslot
        if length(source_slot) >= 13
            date_part = source_slot[1:8]    # "20241015"
            hour_part = source_slot[10:11]  # "00", "01", etc.

            # Generate sub-slots for this period
            for i in 0:(slots_per_source-1)
                minutes = i * target_resolution
                hour_int = parse(Int, hour_part)
                total_minutes = hour_int * 60 + minutes
                final_hour = total_minutes ÷ 60
                final_minute = total_minutes % 60

                slot = "$(date_part)-$(lpad(final_hour, 2, '0'))$(lpad(final_minute, 2, '0'))"
                push!(slots, slot)
            end
        end
    end

    return sort(unique(slots))
end

"""
Disaggregate load and renewable data to the finest temporal resolution.
Returns target_timeslots, load_by_time, and renewable_by_time dictionaries.
"""
function disaggregate_temporal_data(loads, renewables)
    # Detect finest temporal resolution across all data sources
    resolution_minutes, all_resolutions = determine_finest_resolution(loads, renewables)

    if length(all_resolutions) > 1
        println("  📊 Resolution analysis:")
        for res in all_resolutions
            minutes = parse_resolution_to_minutes(res)
            # Determine which data sources have this resolution
            in_loads = !isempty(loads) && any(load.resolution_code == res for load in loads)
            in_renewables = !isempty(renewables) && any(ren.resolution_code == res for ren in renewables)

            data_type = if in_loads && in_renewables
                "Loads & Renewables"
            elseif in_loads
                "Loads"
            elseif in_renewables
                "Renewables"
            else
                "Unknown"
            end
            println("     - $data_type: $res ($(minutes) minutes)")
        end
        println("     → Using finest resolution: $(resolution_minutes) minutes")
    else
        println("  📊 Using resolution: $(resolution_minutes) minutes")
    end

    # Generate target time slots at finest resolution
    load_resolution = parse_resolution_to_minutes(loads[1].resolution_code)

    if load_resolution > resolution_minutes
        # Need to generate finer slots from load data
        load_timeslots = [load.timeslot for load in loads]
        target_timeslots = generate_sub_slots_from_source(load_timeslots, load_resolution, resolution_minutes)
    else
        # Loads already at finest resolution
        target_timeslots = [load.timeslot for load in loads]
    end

    # Disaggregate load data to finest resolution if needed
    load_by_time = Dict{String,Float64}()
    if load_resolution > resolution_minutes
        println("  📊 Disaggregating loads from $(load_resolution)min to $(resolution_minutes)min resolution")
        # Group loads by their timeslot first
        loads_grouped = Dict{String,Float64}()
        for load in loads
            loads_grouped[load.timeslot] = load.value
        end

        # Disaggregate to target timeslots
        for target_slot in target_timeslots
            # Find parent load slot for this target slot
            if length(target_slot) >= 11
                hour_prefix = target_slot[1:11]
                parent_load = nothing
                for (load_slot, load_value) in loads_grouped
                    if length(load_slot) >= 11 && load_slot[1:11] == hour_prefix
                        parent_load = load_value
                        break
                    end
                end

                if parent_load !== nothing
                    # Distribute load evenly across sub-periods
                    slots_per_load = load_resolution ÷ resolution_minutes
                    load_by_time[target_slot] = parent_load / slots_per_load
                end
            end
        end
    else
        # Loads already at finest resolution
        for load in loads
            load_by_time[load.timeslot] = load.value
        end
    end

    # Disaggregate renewable data to finest resolution if needed
    renewable_by_time = Dict{String,Float64}()
    renewable_resolution = !isempty(renewables) ? parse_resolution_to_minutes(renewables[1].resolution_code) : resolution_minutes

    if renewable_resolution > resolution_minutes
        println("  📊 Disaggregating renewables from $(renewable_resolution)min to $(resolution_minutes)min resolution")
        # Group renewables by timeslot first
        renewables_grouped = Dict{String,Float64}()
        for renewable in renewables
            timeslot = renewable.date_time
            if haskey(renewables_grouped, timeslot)
                renewables_grouped[timeslot] += renewable.aggregated_generation_forecast
            else
                renewables_grouped[timeslot] = renewable.aggregated_generation_forecast
            end
        end

        # Disaggregate to target timeslots
        for target_slot in target_timeslots
            if length(target_slot) >= 11
                hour_prefix = target_slot[1:11]
                parent_renewable = 0.0
                for (renewable_slot, renewable_value) in renewables_grouped
                    if length(renewable_slot) >= 11 && renewable_slot[1:11] == hour_prefix
                        parent_renewable += renewable_value
                    end
                end

                if parent_renewable > 0
                    # Distribute renewable evenly across sub-periods
                    slots_per_renewable = renewable_resolution ÷ resolution_minutes
                    renewable_by_time[target_slot] = parent_renewable / slots_per_renewable
                end
            end
        end
    else
        # Renewables already at finest resolution or finer
        for renewable in renewables
            timeslot = renewable.date_time
            if haskey(renewable_by_time, timeslot)
                renewable_by_time[timeslot] += renewable.aggregated_generation_forecast
            else
                renewable_by_time[timeslot] = renewable.aggregated_generation_forecast
            end
        end
    end

    return target_timeslots, load_by_time, renewable_by_time, resolution_minutes
end