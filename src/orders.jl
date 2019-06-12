@enum OrderStatus begin
    Pending = 1
    ExecutionComplete = 2
    Executable = 3
    Expired = 4
    Cancelled = 5
end

mutable struct OrderState
    status::OrderStatus
    id::Union{Nothing,OrderKey}
    sizematched::Float64
    pricematched::Float64
    placedat::Union{Nothing,Dates.DateTime}

    OrderState() = new(Pending, nothing, 0.0, 0.0, nothing)
    OrderState(status::OrderStatus, id::OrderKey, sizematched::Float64, pricematched::Float64, placedat::Dates.DateTime) =
        new(status, id, sizematched, pricematched, placedat)
end

const OrderStatusMap = Dict(zip(map(Symbol∘lowercase∘String∘Symbol, instances(OrderStatus)), instances(OrderStatus)))
orderstatus(key::Symbol) = OrderStatusMap[key]
orderstatus(key::String) = orderstatus(Symbol(lowercase(key)))

marketkey(o::Order) = error("marketkey not implemented by $(typeof(o))")
instruction(o::Order) = error("instruction not implemented by $(typeof(o))")
state(o::Order) = error("state not implemented by $(typeof(o))")

struct LimitOrder <: Order
    marketkey::MarketKey
    runnerkey::RunnerKey
    side::Side
    size::Float64
    price::Float64

    state::OrderState

    LimitOrder(marketkey::MarketKey, runnerkey::RunnerKey, side::Side, size::Float64, price::Float64) =
        new(marketkey, runnerkey, side, size, price, OrderState())
end

marketkey(o::LimitOrder) = o.marketkey
state(o::LimitOrder) = o.state
function instruction(o::LimitOrder)
    Dict(
        "orderType" => "LIMIT",
        "selectionId" => o.runnerkey.id,
        "side" => name(o.side),
        "limitOrder" => Dict(
            "size" => o.size,
            "price" => o.price,
            "persistenceType" => "PERSIST"
        )
    )
end

struct FillOrKillOrder <: Order
    marketkey::MarketKey
    runnerkey::RunnerKey
    side::Side
    size::Float64
    price::Float64
    minsize::Float64

    state::OrderState

    FillOrKillOrder(marketkey::MarketKey, runnerkey::RunnerKey, side::Side, size::Float64, price::Float64) =
        new(marketkey, runnerkey, side, size, price, size, OrderState())

    FillOrKillOrder(marketkey::MarketKey, runnerkey::RunnerKey, side::Side, size::Float64, price::Float64, minsize::Float64) =
        new(marketkey, runnerkey, side, size, price, minsize, OrderState())
end
marketkey(o::FillOrKillOrder) = o.marketkey
state(o::FillOrKillOrder) = o.state
function instruction(o::FillOrKillOrder)
    Dict(
        "orderType" => "LIMIT",
        "selectionId" => o.runnerkey.id,
        "side" => name(o.side),
        "limitOrder" => Dict(
            "size" => o.size,
            "price" => o.price,
            "persistenceType" => "PERSIST",
            "timeInForce" => "FILL_OR_KILL",
            "minSize" => o.minsize
        )
    )
end

function place(s::Session, order::O) where {O<:Order}
    state = Betfair.state(order)
    state.id === nothing || error("Order $(state.id.id) has already been placed")

    params = Dict(
        "marketId" => marketkey(order).id,
        "instructions" => [instruction(order)]
    )
    res = call(s, BettingAPI, "placeOrders", params)
    res["status"] == "SUCCESS" || error("failed to place order $(o) with status $(res["status"])")
    length(res["instructionReports"]) == 1 || error("Unexpected number of instruction reports returned")
    rpt = res["instructionReports"][1]

    state.status = orderstatus(rpt["orderStatus"])
    state.id = OrderKey(rpt["betId"])
    state.sizematched = rpt["sizeMatched"]
    state.pricematched = rpt["averagePriceMatched"]
    state.placedat = Dates.parse(Dates.DateTime, rpt["placedDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ"))

    s.orders[state.id] = order
    order
end

refreshorders(s::Session, market::Market) = refreshorders(s, market.key)
function refreshorders(s::Session, key::MarketKey)
    params = Dict(
        "marketIds" => [key.id],
        "orderProjection" => "ALL",
        "fromRecord" => 0,
        "recordCount" => 1000
    )
    moreavailable = true
    orders = []
    while moreavailable
        res = call(s, BettingAPI, "listCurrentOrders", params)
        params["fromRecord"] += 1000
        moreavailable = res["moreAvailable"]
        for defn in res["currentOrders"]
            order = get!(s.orders, OrderKey(defn["betId"])) do
                # TODO: More accurately track the type of order.
                order = LimitOrder(
                    MarketKey(defn["marketId"]),
                    RunnerKey(defn["selectionId"]),
                    if defn["side"] == "BACK" Back else Lay end,
                    defn["priceSize"]["size"],
                    defn["priceSize"]["price"]
                )
                Betfair.state(order).id = OrderKey(defn["betId"])
            end

            state = Betfair.state(order)
            state.status = orderstatus(defn["status"])
            state.sizematched = defn["sizeMatched"]
            state.pricematched = defn["averagePriceMatched"]
            state.placedat = Dates.parse(Dates.DateTime, defn["placedDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ"))

            push!(orders, order)
        end
    end

    orders
end

function cancel(s::Session, o::O) where {O<:Order}
    state = Betfair.state(o)
    state.status == Executable || error("Can only cancel an executable order")

    params = Dict(
        "marketId" => marketkey(o).id,
        "instructions" => [Dict("betId" => state.id.id)]
    )
    res = call(s, BettingAPI, "cancelOrders", params)
    # TODO: Check that we've actually succeeded and that we've cancelled all outstanding
    state.status = Cancelled
    o
end
