@enum OrderStatus begin
    Pending = 1
    ExecutionComplete = 2
    Executable = 3
    Expired = 4
end

struct OrderKey <: Key
    id::String
end

struct OrderState
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

abstract type Order end
marketkey(o::Order) = error("marketkey not implemented by $(typeof(o))")
instruction(o::Order) = error("instruction not implemented by $(typeof(o))")
state(o::Order) = error("state not implemented by $(typeof(o))")

mutable struct LimitOrder <: Order
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
    params = Dict(
        "marketId" => marketkey(order).id,
        "instructions" => [instruction(order)]
    )
    res = call(s, BettingAPI, "placeOrders", params)
    res["status"] == "SUCCESS" || error("failed to place order $(o) with status $(res["status"])")
    length(res["instructionReports"]) == 1 || error("Unexpected number of instruction reports returned")
    rpt = res["instructionReports"][1]
    order.state = OrderState(
        orderstatus(rpt["orderStatus"]),
        OrderKey(rpt["betId"]),
        rpt["sizeMatched"],
        rpt["averagePriceMatched"],
        Dates.parse(Dates.DateTime, rpt["placedDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ"))
    )
end

function cancel(s::Session, o::O) where {O<:Order}
    state = state(o)
    state.status == Executable || error("Can only cancel an executable order")

    params = Dict(
        "instructions" => [Dict("betId" => state.id.id)]
    )
    res = call(s, BettingAPI, "cancelOrders", params)
end
