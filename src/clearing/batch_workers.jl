# batch_workers.jl — Internal parallel/sequential worker helpers for the batch runners.
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

# =============================================================================
# HELPER FUNCTIONS FOR PARALLEL AND SEQUENTIAL PROCESSING
# =============================================================================

"""
Helper function for processing dates in parallel.
"""
function _process_dates_parallel(dates, order_method, model, optimizer, markup_factor,
    random_seed, silent, save_to_db, max_retries, retry_delay,
    fallback_zones, skip_existing, range_start_time, force_rerun)

    println("📦 Processing $(length(dates)) dates in parallel...")

    # Create arguments tuple for each date
    date_args = [(date, order_method, model, optimizer, markup_factor, random_seed,
        silent, save_to_db, max_retries, retry_delay, fallback_zones,
        skip_existing, range_start_time, force_rerun) for date in dates]

    # Process dates in parallel using pmap
    date_results = pmap(_parallel_date_processor, date_args)

    return date_results
end

"""
Wrapper function for pmap to process a single date.
"""
function _parallel_date_processor(args)
    date, order_method, model, optimizer, markup_factor, random_seed,
    silent, save_to_db, max_retries, retry_delay, fallback_zones,
    skip_existing, range_start_time, force_rerun = args

    date_start_time = time()
    worker_id = myid()

    try
        println("📅 [Worker $worker_id] Processing $date")

        # Process all zones for this date (always sequential in parallel date mode)
        zones_result = generate_energy_prices_for_all_zones(date;
            order_method=order_method,
            model=model,
            optimizer=optimizer,
            markup_factor=markup_factor,
            random_seed=random_seed,
            silent=silent,
            save_to_db=save_to_db,
            max_retries=max_retries,
            retry_delay=retry_delay,
            fallback_zones=fallback_zones,
            skip_existing=skip_existing,
            progress_callback=nothing,  # No callbacks in parallel mode
            parallel=false,  # Always sequential zones in parallel date mode
            max_workers=1,
            chunk_size=1,
            force_rerun=force_rerun)

        date_elapsed = time() - date_start_time
        date_successful = zones_result.success_count > 0

        if date_successful
            println("✅ [Worker $worker_id] Date $date: $(zones_result.success_count)/$(zones_result.total_zones) zones successful ($(round(date_elapsed/60, digits=1)) min)")
        else
            println("❌ [Worker $worker_id] Date $date: All zones failed ($(round(date_elapsed/60, digits=1)) min)")
        end

        return (
            date=date,
            success=date_successful,
            zones_result=zones_result,
            elapsed_time=date_elapsed,
            zones_discovered=zones_result.total_zones,
            zones_successful=zones_result.success_count,
            zones_failed=zones_result.failure_count,
            zones_skipped=zones_result.skipped_count,
            worker_id=worker_id
        )

    catch date_error
        date_elapsed = time() - date_start_time
        println("❌ [Worker $worker_id] Date $date: CRITICAL FAILURE - $date_error ($(round(date_elapsed/60, digits=1)) min)")

        return (
            date=date,
            success=false,
            zones_result=nothing,
            elapsed_time=date_elapsed,
            zones_discovered=0,
            zones_successful=0,
            zones_failed=0,
            zones_skipped=0,
            worker_id=worker_id
        )
    end
end

"""
Generate daily summaries from parallel date processing results.
"""
function _generate_daily_summaries(date_results)
    daily_summaries = NamedTuple[]

    for result in date_results
        if result.success && result.zones_result !== nothing
            zones_result = result.zones_result

            if zones_result.success_count > 0
                successful_results = filter(r -> r.success, zones_result.results)
                all_prices = Float64[]
                total_periods = 0

                for zone_result in successful_results
                    if !isempty(zone_result.prices)
                        append!(all_prices, collect(values(zone_result.prices)))
                        total_periods += zone_result.periods
                    end
                end

                if !isempty(all_prices)
                    daily_summary = (
                        date=result.date,
                        zones_total=zones_result.total_zones,
                        zones_successful=zones_result.success_count,
                        success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                        avg_price=round(sum(all_prices) / length(all_prices), digits=2),
                        min_price=round(minimum(all_prices), digits=2),
                        max_price=round(maximum(all_prices), digits=2),
                        total_periods=total_periods
                    )
                else
                    daily_summary = (
                        date=result.date,
                        zones_total=zones_result.total_zones,
                        zones_successful=0,
                        success_rate=0.0,
                        avg_price=0.0,
                        min_price=0.0,
                        max_price=0.0,
                        total_periods=0
                    )
                end
            else
                daily_summary = (
                    date=result.date,
                    zones_total=zones_result.total_zones,
                    zones_successful=0,
                    success_rate=0.0,
                    avg_price=0.0,
                    min_price=0.0,
                    max_price=0.0,
                    total_periods=0
                )
            end
        else
            daily_summary = (
                date=result.date,
                zones_total=0,
                zones_successful=0,
                success_rate=0.0,
                avg_price=0.0,
                min_price=0.0,
                max_price=0.0,
                total_periods=0
            )
        end
        push!(daily_summaries, daily_summary)
    end

    return daily_summaries
end

"""
Helper function for processing zones sequentially.
"""
function _process_zones_sequential(zones_to_process, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay, progress_callback, start_time, force_rerun)
    results = NamedTuple[]

    for (i, zone) in enumerate(zones_to_process)
        zone_start_time = time()

        println("\n🏃 [$i/$(length(zones_to_process))] Zone: $zone")
        println("-"^40)

        # Try processing with retries
        zone_success = false
        zone_prices = Dict{String,Float64}()
        zone_error = ""
        attempts = 0

        for attempt in 1:max_retries
            attempts = attempt
            attempt_start = time()  # Move outside try block
            try
                retry_msg = attempt > 1 ? " (retry $attempt/$max_retries)" : ""
                println("🔄 Processing: $zone$retry_msg")

                zone_prices = generate_energy_prices(zone, date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    force_rerun=force_rerun)

                if !isempty(zone_prices)
                    zone_success = true

                    min_price = minimum(values(zone_prices))
                    max_price = maximum(values(zone_prices))
                    avg_price = sum(values(zone_prices)) / length(zone_prices)
                    elapsed = time() - attempt_start

                    println("✅ SUCCESS: $zone ($(round(elapsed, digits=2))s)")
                    println("   💰 $(length(zone_prices)) periods: €$(round(min_price, digits=2)) - €$(round(max_price, digits=2))/MWh (avg: €$(round(avg_price, digits=2)))")
                    break
                else
                    zone_error = "No prices generated"
                    if attempt < max_retries
                        println("⚠️  No prices generated for $zone, retrying...")
                        sleep(retry_delay)
                    end
                end

            catch e
                zone_error = string(e)
                elapsed = time() - attempt_start

                # Check if this is a non-retryable error (data availability)
                is_retryable = !(e isa DataUnavailableError)

                if is_retryable && attempt < max_retries
                    println("❌ ATTEMPT $attempt FAILED: $zone ($(round(elapsed, digits=2))s)")
                    println("   📝 Error: $(first(split(zone_error, '\n')))")
                    println("   🔄 Retrying in $(retry_delay)s...")
                    sleep(retry_delay)
                else
                    if e isa DataUnavailableError
                        println("❌ DATA NOT AVAILABLE: $zone ($(round(elapsed, digits=2))s)")
                        println("   📝 Reason: $(first(split(zone_error, '\n')))")
                        println("   ⚠️  Skipping retries - data availability issue")
                    else
                        println("❌ FINAL FAILURE: $zone ($(round(elapsed, digits=2))s after $max_retries attempts)")
                        println("   📝 Error: $(first(split(zone_error, '\n')))")
                    end
                    break  # Exit retry loop
                end
            end
        end

        zone_elapsed = time() - zone_start_time

        # Calculate price statistics
        min_price = zone_success ? minimum(values(zone_prices)) : 0.0
        max_price = zone_success ? maximum(values(zone_prices)) : 0.0
        avg_price = zone_success && !isempty(zone_prices) ? sum(values(zone_prices)) / length(zone_prices) : 0.0

        # Store result
        zone_result = (
            zone=zone,
            success=zone_success,
            prices=zone_prices,
            periods=length(zone_prices),
            elapsed_time=zone_elapsed,
            min_price=min_price,
            max_price=max_price,
            avg_price=avg_price,
            error_message=zone_success ? "" : zone_error,
            attempt=attempts,
            worker_id=1
        )
        push!(results, zone_result)

        # Call progress callback if provided
        if progress_callback !== nothing
            try
                progress_callback(zone, i, length(zones_to_process), zone_elapsed)
            catch callback_error
                @warn "Progress callback failed: $callback_error"
            end
        end

        # Progress update
        total_elapsed = time() - start_time
        remaining = length(zones_to_process) - i
        est_remaining = remaining > 0 ? total_elapsed / i * remaining / 60 : 0
        println("   📈 Progress: $i/$(length(zones_to_process)) | Est. remaining: $(round(est_remaining, digits=1)) min")
    end

    return results
end

"""
Helper function for processing zones in parallel.
"""
function _process_zones_parallel(zones_to_process, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay, progress_callback, chunk_size, force_rerun)

    # Split zones into chunks for distribution
    zone_chunks = [zones_to_process[i:min(i + chunk_size - 1, end)] for i in 1:chunk_size:length(zones_to_process)]

    println("📦 Split $(length(zones_to_process)) zones into $(length(zone_chunks)) chunks of size $chunk_size")

    # Prepare arguments for pmap
    pmap_args = [(chunk, date, order_method, model, optimizer, markup_factor, random_seed, silent, save_to_db, max_retries, retry_delay, force_rerun) for chunk in zone_chunks]

    # Process chunks in parallel
    chunk_start_time = time()

    # Use pmap for parallel processing of chunks
    chunk_results = pmap(_parallel_chunk_processor, pmap_args)

    # Flatten results from all chunks
    results = NamedTuple[]
    processed_count = 0

    for chunk_result in chunk_results
        for zone_result in chunk_result
            push!(results, zone_result)
            processed_count += 1

            # Call progress callback if provided (less frequently in parallel mode)
            if progress_callback !== nothing && processed_count % max(1, div(length(zones_to_process), 10)) == 0
                try
                    elapsed = time() - chunk_start_time
                    progress_callback(zone_result.zone, processed_count, length(zones_to_process), elapsed)
                catch callback_error
                    @warn "Progress callback failed: $callback_error"
                end
            end
        end
    end

    println("⚡ Parallel processing completed in $(round((time() - chunk_start_time)/60, digits=1)) minutes")

    return results
end

"""
Wrapper function for pmap to process a chunk of zones.
"""
function _parallel_chunk_processor(args)
    zone_chunk, date, order_method, model, optimizer, markup_factor, random_seed, silent, save_to_db, max_retries, retry_delay, force_rerun = args
    return _process_zone_chunk(zone_chunk, date, order_method, model, optimizer,
        markup_factor, random_seed, silent, save_to_db,
        max_retries, retry_delay, force_rerun)
end

"""
Process a chunk of zones on a single worker.
"""
function _process_zone_chunk(zone_chunk, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay, force_rerun)
    worker_id = myid()
    chunk_results = NamedTuple[]

    for zone in zone_chunk
        zone_start_time = time()

        # Try processing with retries
        zone_success = false
        zone_prices = Dict{String,Float64}()
        zone_error = ""
        attempts = 0

        for attempt in 1:max_retries
            attempts = attempt
            try
                zone_prices = generate_energy_prices(zone, date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    force_rerun=force_rerun)

                if !isempty(zone_prices)
                    zone_success = true
                    break
                else
                    zone_error = "No prices generated"
                    if attempt < max_retries
                        sleep(retry_delay)
                    end
                end

            catch e
                zone_error = string(e)
                if attempt < max_retries
                    sleep(retry_delay)
                end
            end
        end

        zone_elapsed = time() - zone_start_time

        # Calculate price statistics
        min_price = zone_success ? minimum(values(zone_prices)) : 0.0
        max_price = zone_success ? maximum(values(zone_prices)) : 0.0
        avg_price = zone_success && !isempty(zone_prices) ? sum(values(zone_prices)) / length(zone_prices) : 0.0

        # Store result
        zone_result = (
            zone=zone,
            success=zone_success,
            prices=zone_prices,
            periods=length(zone_prices),
            elapsed_time=zone_elapsed,
            min_price=min_price,
            max_price=max_price,
            avg_price=avg_price,
            error_message=zone_success ? "" : zone_error,
            attempt=attempts,
            worker_id=worker_id
        )
        push!(chunk_results, zone_result)
    end

    return chunk_results
end
