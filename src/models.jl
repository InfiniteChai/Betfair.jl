struct Competition
    name::String
    id::String
    marketcount::Int32
    region::String
end

function unwrap(data, ::Type{Competition})
    return Competition(
        data["competition"]["name"],
        data["competition"]["id"],
        data["marketCount"],
        data["competitionRegion"]
    )
end

struct Event
    name::String
    id::String
    countrycode::String
    timezone::String
    opendate::Dates.DateTime
    marketcount::Int32
end

function unwrap(data, ::Type{Event})
    return Event(
        data["event"]["name"],
        data["event"]["id"],
        data["event"]["countryCode"],
        data["event"]["timezone"],
        Dates.parse(Dates.DateTime, data["event"]["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")),
        data["marketCount"]
    )
end

struct MarketInfo
    starttime::Dates.DateTime
    turninplay::Bool
    markettype::String
    marketbaserate::Float64
end

struct Runner
    name::String
    id::Int32
end

struct Market
    name::String
    id::String
    event::Event
    info::MarketInfo
    runners::Dict{Int64,Runner}
end

function unwrap(data, event::Event, ::Type{Market})
    return Market(
        data["marketName"],
        data["marketId"],
        event,
        MarketInfo(
            Dates.parse(Dates.DateTime, data["marketStartTime"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")),
            data["description"]["turnInPlayEnabled"],
            data["description"]["marketType"],
            data["description"]["marketBaseRate"]
        ),
        Dict(x["selectionId"] => Runner(x["runnerName"], x["selectionId"]) for x in data["runners"])
    )
end

struct PriceSize
    price::Float64
    size::Float64
end

unwrap(data, ::Type{PriceSize}) = PriceSize(data["price"], data["size"])

@auto_hash_equals struct RunnerBook
    runner::Runner
    lastpricetraded::Union{Nothing,Float64}
    totalmatched::Union{Nothing,Float64}
    status::String
    backprices::Vector{PriceSize}
    layprices::Vector{PriceSize}
end

@auto_hash_equals struct MarketBook
    market::Market
    lastmatchtime::Dates.DateTime
    status::String # Change this to an enum!
    inplay::Bool
    totalmatched::Float64
    runners::Dict{Runner,RunnerBook}
end

function unwrap(data, market::Market, ::Type{RunnerBook})
    RunnerBook(
        market.runners[data["selectionId"]],
        get(data, "lastPriceTraded", nothing),
        get(data, "totalMatched", nothing),
        data["status"],
        map(x -> unwrap(x, PriceSize), get(data, "ex", Dict("availableToBack" => []))["availableToBack"]),
        map(x -> unwrap(x, PriceSize), get(data, "ex", Dict("availableToLay" => []))["availableToLay"]),
    )
end

function unwrap(data, market::Market, ::Type{MarketBook})
    runners = map(x -> unwrap(x, market, RunnerBook), data["runners"])

    MarketBook(
        market,
        Dates.parse(Dates.DateTime, data["lastMatchTime"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")),
        data["status"],
        data["inplay"],
        data["totalMatched"],
        Dict(x.runner => x for x in runners)
    )
end
