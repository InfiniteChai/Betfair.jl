@enum OrderStatus begin
    Pending = 1
    ExecutionComplete = 2
    Executable = 3
    Expired = 4
    Cancelled = 5
end

const OrderStatusMap = Dict(zip(map(Symbol∘lowercase∘String∘Symbol, instances(OrderStatus)), instances(OrderStatus)))
orderstatus(key::Symbol) = OrderStatusMap[key]
orderstatus(key::String) = orderstatus(Symbol(lowercase(key)))

abstract type OrderInstruction end

struct Order{OI<:OrderInstruction} <: AbstractOrder
    id::OrderKey
    market::MarketKey
    runner::RunnerKey
    status::OrderStatus
    placedat::Dates.DateTime
    sizematched::Float64
    pricematched::Float64
    strategyref::Union{Nothing,String}
    instruction::OI
end


abstract type PriceInstruction end
struct FixedPrice <: PriceInstruction
    price::Float64
end
struct AtMarketPrice <: PriceInstruction
end

struct LimitOrderInstruction{PI<:PriceInstruction} <: OrderInstruction
    market::MarketKey
    runner::RunnerKey
    side::Side
    size::Float64
    priceinstruction::PI
end

price(o::LimitOrderInstruction{FixedPrice}) = o.priceinstruction.price
price(o::LimitOrderInstruction{AtMarketPrice}) = if o.side == Back 1 else 1000 end
marketkey(o::LimitOrderInstruction{<:PriceInstruction}) = o.market
runnerkey(o::LimitOrderInstruction{<:PriceInstruction}) = o.runner

function instruction(o::LimitOrderInstruction{<:PriceInstruction})
    Dict(
        "orderType" => "LIMIT",
        "selectionId" => o.runner.id,
        "side" => name(o.side),
        "limitOrder" => Dict(
            "size" => o.size,
            "price" => price(o),
            "persistenceType" => "PERSIST"
        )
    )
end

struct FillOrKillOrderInstruction{PI<:PriceInstruction} <: OrderInstruction
    market::MarketKey
    runner::RunnerKey
    side::Side
    size::Float64
    price::PI
    minsize::Float64

    FillOrKillOrderInstruction(market::MarketKey, runner::RunnerKey, side::Side, size::Float64, price::PI) where {PI<:PriceInstruction} =
        new{PI}(market, runner, side, size, price, size)
    FillOrKillOrderInstruction(market::MarketKey, runner::RunnerKey, side::Side, size::Float64, price::PI, minsize::Float64) where {PI<:PriceInstruction} =
        new{PI}(market, runner, side, size, price, size, minsize)
end

price(o::FillOrKillOrderInstruction{FixedPrice}) = o.priceinstruction.price
price(o::FillOrKillOrderInstruction{AtMarketPrice}) = if o.side == Back 1 else 1000 end
marketkey(o::FillOrKillOrderInstruction{<:PriceInstruction}) = o.market
runnerkey(o::FillOrKillOrderInstruction{<:PriceInstruction}) = o.runner

function instruction(o::FillOrKillOrderInstruction{<:PriceInstruction})
    Dict(
        "orderType" => "LIMIT",
        "selectionId" => o.runner.id,
        "side" => name(o.side),
        "limitOrder" => Dict(
            "size" => o.size,
            "price" => price(o),
            "persistenceType" => "PERSIST",
            "timeInForce" => "FILL_OR_KILL",
            "minSize" => o.minsize
        )
    )
end

function place(s::Session, order::OI; ref = nothing) where {OI<:OrderInstruction}
    params = Dict(
        "marketId" => marketkey(order).id,
        "instructions" => [instruction(order)]
    )

    if ref !== nothing
        length(ref) <= 15 || error("Strategy reference '$(ref)' is too long")
        params["customerStrategyRef"] = ref
    end

    res = call(s, BettingAPI, "placeOrders", params)
    res["status"] == "SUCCESS" || error("failed to place order instruction $(order) with status $(res["status"])")
    length(res["instructionReports"]) == 1 || error("Unexpected number of instruction reports returned")
    rpt = res["instructionReports"][1]

    actualorder = Order(
        OrderKey(rpt["betId"]),
        marketkey(order),
        runnerkey(order),
        orderstatus(rpt["orderStatus"]),
        Dates.parse(Dates.DateTime, rpt["placedDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")),
        rpt["sizeMatched"],
        rpt["averagePriceMatched"],
        ref,
        order
    )

    s.orders[actualorder.id] = actualorder
end

# We need to add handling to pick up EXECUTABLE or EXECUTION_COMPLETE when
# they weren't submitted from this session.

# Also refresh should clean up any orders in

function refreshorders(s::Betfair.Session)
    params = Dict(
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
            order = s.orders[OrderKey(defn["betId"])]
            neworder = Order(
                order.id,
                order.market,
                order.runner,
                orderstatus(defn["status"]),
                order.placedat,
                defn["sizeMatched"],
                defn["averagePriceMatched"],
                order.strategyref,
                order.instruction
            )
            s.orders[OrderKey(defn["betId"])] = neworder
            push!(orders, neworder)
        end
    end

    orders
end

function cancel(s::Session, order::Order)
    order.status == Executable || error("Can only cancel an executable order")

    params = Dict(
        "marketId" => order.market.id,
        "instructions" => [Dict("betId" => order.id.id)]
    )
    res = call(s, BettingAPI, "cancelOrders", params)
    # TODO: Check that we've actually succeeded and that we've cancelled all outstanding

    neworder = Order(
        order.id,
        order.market,
        order.runner,
        Cancelled,
        order.placedat,
        order.sizematched,
        order.pricematched,
        order.strategyref,
        order.instruction
    )

    s.orders[order.id] = neworder
end
