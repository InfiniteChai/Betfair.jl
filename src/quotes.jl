struct Quote
    side::Side
    price::Float64
    size::Float64
end

struct RunBook
    backdepth::Vector{Quote}
    laydepth::Vector{Quote}
end

struct MarketBook
    market::MarketKey
    inplay::Bool
    runbooks::Dict{RunnerKey, RunBook}
end

bestback(book::RunBook)::Union{Quote,Nothing} = length(book.backdepth) > 0 ? book.backdepth[1] : nothing
bestlay(book::RunBook)::Union{Quote,Nothing} = length(book.laydepth) > 0 ? book.laydepth[1] : nothing

marketbook(s::Session, key::MarketKey) = marketbook(s, market(s, key))
function marketbook(s::Session, market::Market)
    params = Dict(
        "marketIds" => [market.key.id],
        "priceProjection" => Dict(
            "priceData" => [ "EX_ALL_OFFERS" ]
        )
    )

    results = call(s, BettingAPI, "listMarketBook", params)
    length(results) == 1 || error("Expected one market book result for $(market.key.id)")
    marketbook = results[1]
    rs = runners(s, market)
    runbooks = Dict()
    for runbook in marketbook["runners"]
        runner = rs[RunnerKey(runbook["selectionId"])]
        runbooks[runner.key] = RunBook(
            map(x -> Quote(Back, x["price"], x["size"]), runbook["ex"]["availableToBack"]),
            map(x -> Quote(Lay, x["price"], x["size"]), runbook["ex"]["availableToLay"])
        )
    end

    MarketBook(market.key, marketbook["inplay"], runbooks)
end
