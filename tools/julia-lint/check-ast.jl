# Parse source only: no includes, evaluation, packages or database access.
# julia check-ast.jl FILES.nul ORIGINAL_ROOT FORMATTED_ROOT REPORT.toml
using TOML

function strip_locations(value)
    if value isa Expr
        return Expr(
            value.head,
            (strip_locations(arg) for arg in value.args if !(arg isa LineNumberNode))...,
        )
    elseif value isa QuoteNode
        return QuoteNode(strip_locations(value.value))
    elseif value isa LineNumberNode
        return nothing
    end
    return value
end

function parse_failure(value)
    value isa Expr || return false
    value.head in (:error, :incomplete) && return true
    return any(parse_failure, value.args)
end

function first_difference(a, b, location="root")
    isequal(a, b) && return nothing
    if a isa Expr && b isa Expr && a.head == b.head && length(a.args) == length(b.args)
        for index in eachindex(a.args)
            diff = first_difference(
                a.args[index],
                b.args[index],
                "$location.$(a.head)[$index]",
            )
            diff === nothing || return diff
        end
    end
    brief(x) = first(repr(x), min(500, length(repr(x))))
    return Dict("location" => location, "original" => brief(a), "formatted" => brief(b))
end

function main()
    length(ARGS) == 4 ||
        error("usage: check-ast.jl FILES.nul ORIGINAL_ROOT FORMATTED_ROOT REPORT.toml")
    files = split(read(ARGS[1], String), '\0'; keepempty=false)
    records = Dict{String, Any}[]
    for file in files
        record = Dict{String, Any}("file" => file)
        try
            original = Meta.parseall(
                read(joinpath(ARGS[2], file), String);
                filename="audit.jl",
            )
            formatted = Meta.parseall(
                read(joinpath(ARGS[3], file), String);
                filename="audit.jl",
            )
            if parse_failure(original)
                record["status"] = "original_parse_failure"
            elseif parse_failure(formatted)
                record["status"] = "formatted_parse_failure"
            else
                a, b = strip_locations(original), strip_locations(formatted)
                difference = first_difference(a, b)
                record["status"] = difference === nothing ? "equal" : "different"
                difference === nothing || (record["difference"] = difference)
            end
        catch err
            record["status"] = "exception"
            record["error"] = sprint(showerror, err)
        end
        push!(records, record)
    end
    report = Dict(
        "julia" => string(VERSION),
        "files" => length(records),
        "records" => records,
    )
    open(ARGS[4], "w") do io
        TOML.print(io, report; sorted=true)
    end
    for status in sort(unique(record["status"] for record in records))
        println(status, ": ", count(record -> record["status"] == status, records))
    end
    all(record -> record["status"] == "equal", records) || exit(1)
end
main()
