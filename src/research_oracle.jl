# Runtime-only lookahead for quantity ablations on a read-only research extract.
const ORACLE_FLAGS = ("EUPHEMIA_ORACLE_HYDRO", "EUPHEMIA_ORACLE_FLOWS", "EUPHEMIA_ORACLE_FUND")
const ORACLE_ENV = ("EUPHEMIA_RESEARCH_ORACLE", "EUPHEMIA_ORACLE_ZONES", ORACLE_FLAGS...)

function research_oracle(env=ENV; backend=DATA_STORE[], read_only=DUCKDB_READ_ONLY[])
    values = map(k -> get(env, k, "off"), ORACLE_FLAGS)
    all(v -> v in ("on", "off", ""), values) || error("Oracle switches accept on or off")
    "on" in values || return nothing
    get(env, "EUPHEMIA_RESEARCH_ORACLE", "") == "1" || error("Oracle lookahead requires EUPHEMIA_RESEARCH_ORACLE=1")
    backend == :duckdb && read_only || error("Oracle lookahead requires a read-only DuckDB extract")
    zones = Set(String(strip(z)) for z in split(get(env, "EUPHEMIA_ORACLE_ZONES", ""), ',') if !isempty(strip(z)))
    isempty(zones) && return nothing
    return (; zones, hydro=values[1] == "on", flows=values[2] == "on", fund=values[3] == "on")
end
