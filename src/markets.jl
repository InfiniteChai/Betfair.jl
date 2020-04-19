export markets, marketbook, marketbooks

markets(s::Session, name::String) = markets(s, event(s, name))

markets(s::Session, event::Event) = get!(s.state.marketsbyevent, event.id) do
    fields = ["MARKET_DESCRIPTION", "MARKET_START_TIME", "RUNNER_DESCRIPTION", "RUNNER_METADATA"]
    params = Dict{String,Any}("filter" => Dict{String,Any}("eventIds" => [event.id]), "maxResults" => 1000, "marketProjection" => fields)
    res = call(s, BettingAPI, "listMarketCatalogue", params)
    markets = map(x -> unwrap(x, event, Market), res)
    for market in markets
        s.state.markets[market.id] = market
    end

    markets
end

marketbook(s::Session, market::Market) = marketbooks(s, [market])[1]
marketbooks(s::Session, event::Event) = marketbooks(s, markets(s, event))
function marketbooks(s::Session, markets::Vector{Market})
    params = Dict{String,Any}("marketIds" => map(x -> x.id, markets), "priceProjection" => Dict{String,Any}("priceData" => ["EX_ALL_OFFERS"]), "orderProjection" => "EXECUTABLE")
    res = call(s, BettingAPI, "listMarketBook", params)
    return (unwrap(data, market, MarketBook) for (data,market) in zip(res, markets)) |> collect
end
