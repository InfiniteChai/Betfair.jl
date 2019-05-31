module Betfair

using HTTP
using JSON
import Dates
using Pkg.TOML
import Memoize
import Libz
import Match

abstract type API end
struct BettingAPI <: API end
full_method(::Type{BettingAPI}, method::String) = "SportsAPING/v1.0/$(method)"
endpoint(::Type{BettingAPI}) = "https://api.betfair.com/exchange/betting/json-rpc/v1"

struct AccountsAPI <: API end
full_method(::Type{AccountsAPI}, method::String) = "AccountAPING/v1.0/$(method)"
endpoint(::Type{AccountsAPI}) = "https://api.betfair.com/exchange/account/json-rpc/v1"

mutable struct Session
    msgid::Int32
    token::Union{Nothing,String}
    appid::String

    Session(appid::String) = new(0, nothing, appid)
end

function headers(s::Session; accept = "application/json", content = "application/json") :: Dict{String, String}
    headers = Dict("Accept" => accept, "Content-Type" => content, "X-Application" => s.appid, "Accept-Encoding" => "gzip, deflate")
    if s.token !== nothing
        headers["X-Authentication"] = s.token
    end

    return headers
end

function connect(s::Session, username::String, password::String) :: String
    h = headers(s; content="application/x-www-form-urlencoded")
    b = HTTP.URIs.escapeuri(Dict("username" => username, "password" => password))
    result = HTTP.request("POST", "https://identitysso.betfair.com/api/login"; headers=h, body=b)
    body = JSON.Parser.parse(String(result.body))
    body["status"] == "SUCCESS" || throw(error("Login Failed: $(body["error"])"))
    s.token = body["token"]
end

const APP_SESSIONS = Dict{Symbol,Session}()

function initsession()
    settings = TOML.parsefile("cfg\\settings.toml")
    s = Betfair.Session(settings["account"]["appid"])
    Betfair.connect(s, settings["account"]["username"], settings["account"]["password"])
    return s
end

function keepalive(s::Session)
    h = headers(s)
    result = HTTP.request("POST", "https://identitysso.betfair.com/api/keepAlive"; headers=h)
    body = JSON.Parser.parse(String(result.body))
    body["status"] == "SUCCESS" || throw(error("Failed to keepAlive Session $(s["appid"])"))
end

function call(s::Session, api::Type{T}, method::String, params::Dict{String, Any}) where {T <: API}
    s.token !== nothing || throw(error("Login before making a call"))
    h = headers(s)
    msg = Dict("jsonrpc" => "2.0", "method" => full_method(api, method), "id" => s.msgid, "params" => params)
    s.msgid += 1
    result = HTTP.request("POST", endpoint(api); headers=h, body=JSON.json(msg))
    body = result.body |> Libz.ZlibInflateInputStream |> readline |> JSON.Parser.parse
    !haskey(body, "error") || throw(error("Failed to call $(method) with code $(body["error"]["code"])"))
    return body["result"]
end

abstract type Event end
abstract type AbstractMarket{E <: Event} end

struct Runner{E <: Event, M <: AbstractMarket{E}}
    name::String
    id::Int64
    market::M
end

mutable struct Market{E <: Event} <: AbstractMarket{E}
    name::String
    id::String
    event::E
    _runners::Dict{String,Runner{E, Market{E}}}

    Market(name::String, id::String, event::E) where {E <: Event} = new{E}(name, id, event, Dict{String,Runner{E, Market{E}}}())
end

struct Competition
    name::String
    id::String
    region::String
end

mutable struct FootballEvent <: Event
    name::String
    id::String
    competition::Competition
    _markets::Dict{String,Market{FootballEvent}}
    starttime::Dates.DateTime
    FootballEvent(name::String, id::String, comp::Competition, starttime::Dates.DateTime) = new(name, id, comp, Dict{String,Market{FootballEvent}}(), starttime)
end

@enum Side begin
    Back = 1
    Lay = -1
end

struct Quote
    side::Side
    price::Float64
    size::Float64
end

struct QuoteStack
    backdepth::Vector{Quote}
    laydepth::Vector{Quote}
end

bestback(qs::QuoteStack) :: Union{Nothing,Quote} = length(qs.backdepth) > 0 ? qs.backdepth[1] : nothing
bestlay(qs::QuoteStack) :: Union{Nothing,Quote} = length(qs.laydepth) > 0 ? qs.laydepth[1] : nothing

Memoize.@memoize function listeventtypes(s::Session)
    res = call(s, BettingAPI, "listEventTypes", Dict{String,Any}("filter" => Dict{String,Any}()))
    types = Dict(map(x->Symbol(lowercase(x["eventType"]["name"])), res) .=> map(x->x["eventType"]["id"], res))
    for (k,v) in EVENT_TYPE_OVERRIDES
        types[k] = types[v]
    end

    return types
end

function inplaytimeline(s::Session, e::FootballEvent)
    res = HTTP.request("GET", "https://ips.betfair.com/inplayservice/v1/eventTimeline?alt=json&eventId=$(e.id)&locale=en_GB&productType=EXCHANGE&regionCode=UK")
    body = JSON.Parser.parse(String(res.body))
    length(body) != 0 || return Dict{String,Any}("status" => "NOT_IN_PLAY")
    # Reduce it to data we're interested in at the moment.
    return Dict{String,Any}(
        "elapsedtime" => body["timeElapsed"],
        "status" => body["status"],
        "elapsedregulartime" => body["elapsedRegularTime"],
        "score" => (parse(Int8, body["score"]["home"]["score"]), parse(Int8,body["score"]["away"]["score"]))
    )
end

function markets(session::Session, event::Event; refresh::Bool = false)
    if length(event._markets) == 0 || refresh
        params = Dict{String,Any}("filter" => Dict{String,Any}("eventIds" => [event.id]), "maxResults" => 1000)
        results = call(session, BettingAPI, "listMarketCatalogue", params)
        for result in results
            market = Market(result["marketName"], result["marketId"], event)
            event._markets[market.name] = market
        end
    end
    return event._markets
end

function runners(session::Session, market::Market{E}; refresh::Bool = false) where {E <: Event}
    if length(market._runners) == 0 || refresh
        params = Dict{String,Any}("filter" => Dict{String,Any}("marketIds" => [market.id]), "maxResults" => 1000, "marketProjection" => ["RUNNER_DESCRIPTION"])
        results = call(session, BettingAPI, "listMarketCatalogue", params)
        length(results) == 1 || error("Expect only one entry in market catalogue for $(market.name), found $(length(results))")
        for entry in results[1]["runners"]
            runner = Runner{E, typeof(market)}(entry["runnerName"], entry["selectionId"], market)
            market._runners[runner.name] = runner
        end
    end

    return market._runners
end


function findevent(session::Session, name::String, eventtype::Symbol)
    eventtypeid = listeventtypes(session)[eventtype]
    params = Dict{String,Any}("filter" => Dict{String,Any}("textQuery" => name, "eventTypeIds" => [eventtypeid]))
    res = call(session, BettingAPI, "listEvents", params)
    length(res) == 1 || error("Only expected one event with name $(name), found $(length(res))")
    return Match.@match eventtype begin
        :football || :soccer  => begin
            compparams = Dict{String,Any}("filter" => Dict{String,Any}("eventIds" => [res[1]["event"]["id"]]))
            compinfo = call(session, BettingAPI, "listCompetitions", compparams)[1]
            comp = Competition(compinfo["competition"]["name"], compinfo["competition"]["id"], compinfo["competitionRegion"])
            FootballEvent(res[1]["event"]["name"], res[1]["event"]["id"], comp, Dates.parse(Dates.DateTime, res[1]["event"]["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")))
        end
        _                       => error("Don't know how to handl event type $(eventtype)")
    end
end

function marketdata(session::Session, market::Market{E}) where {E <: Event}
    params = Dict{String,Any}("marketIds" => [market.id], "priceProjection" => Dict{String,Any}("priceData" => ["EX_ALL_OFFERS"]))
    results = call(session, BettingAPI, "listMarketBook", params)
    length(results) == 1 || error("Expected only one entry in market book for $(market.name), found $(length(results))")
    resbyrunner = reduce((x,y) -> (x[y["selectionId"]] = y; x), results[1]["runners"]; init=Dict{Int64,Any}())
    ret = Dict{Runner{E, Market{E}}, QuoteStack}()
    for (name,runner) in runners(session, market)
        offers = resbyrunner[runner.id]["ex"]
        ret[runner] = QuoteStack(map(x -> Quote(Back, x["price"], x["size"]), offers["availableToBack"]), map(x -> Quote(Lay, x["price"], x["size"]), offers["availableToLay"]))
    end
    return ret
end

getaccountfunds(s::Session) = call(s, AccountsAPI, "getAccountFunds", Dict{String,Any}())
getaccountdetails(s::Session) = call(s, AccountsAPI, "getAccountDetails", Dict{String,Any}())
getaccountstatement(s::Session) = call(s, AccountsAPI, "getAccountStatement", Dict{String,Any}())

# Some specific overrides to standard terminology for
const EVENT_TYPE_OVERRIDES = Dict{Symbol, Symbol}(:football => :soccer)

function extendevent(event)
    return Dict("openDateTime" => Dates.parse(Dates.DateTime, event["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")))
end

function listevents(s::Session, event::String)
    eventtypes = listeventtypes(s)
    res = call(s, BettingAPI, "listEvents", Dict{String,Any}("filter" => Dict{String,Any}("eventTypeIds" => [eventtypes[event]])))
    events = Dict(map(x->x["event"]["id"], res) .=> map(x->merge(extendevent(x["event"]),x["event"]), res))
    return events
end

function getmarketcatalogue(s::Session, event::String)
    params = Dict{String,Any}("filter" => Dict{String,Any}("eventIds" => [event]), "maxResults" => 1000)
    return call(s, BettingAPI, "listMarketCatalogue", params)
end

function geteventmarkets(s::Session, eventId::String; pivot::Symbol = :name)
    fields = ["MARKET_DESCRIPTION"]
    params = Dict{String,Any}("filter" => Dict{String,Any}("eventIds" => [eventId]), "maxResults" => 1000, "marketProjection" => fields)
    res = call(s, BettingAPI, "listMarketCatalogue", params)
    pivotres = Match.@match pivot begin
        :name   => reduce((x,y) -> (x[y["marketName"]] = y; x), res; init=Dict{String,Any}())
        _       => error("Unknown pivot $(pivot) for event markets")
    end

    return pivotres
end

function getmarketrunners(s::Session, marketId::String, pivot::Symbol = :name)
    fields = ["RUNNER_DESCRIPTION"]
    params = Dict{String,Any}("filter" => Dict{String,Any}("marketIds" => [marketId]), "maxResults" => 1000, "marketProjection" => fields)
    res = call(s, BettingAPI, "listMarketCatalogue", params)
    length(res) == 1 || error("Expected exactly one entry in catalogue for $(event), found $(length(res))")
    runners = res[1]["runners"]
    pivotrunners = Match.@match pivot begin
        :name   => reduce((x,y) -> (x[y["runnerName"]] = y; x), runners; init=Dict{String,Any}())
        _       => error("Unknown pivot $(pivot) for event markets")
    end
    return pivotrunners
end

function getmarketbook(s::Session, marketId::String)
    params = Dict{String,Any}("marketIds" => [marketId], "priceProjection" => Dict{String,Any}("priceData" => ["EX_ALL_OFFERS"]), "orderProjection" => "EXECUTABLE")
    res = call(s, BettingAPI, "listMarketBook", params)
    return res
end

function getrunnerbook(s::Session, marketId::String, runnerId::Int64)
    params = Dict{String,Any}("marketId" => marketId, "selectionId" => runnerId)
    res = call(s, BettingAPI, "listRunnerBook", params)
    return res
end

function listcurrentorders(s::Session; requestinc = 1000)
    res = call(s, BettingAPI, "listCurrentOrders", Dict{String,Any}("recordCount" => requestinc))
    orders = res["currentOrders"]; fromidx = requestinc;
    while res["moreAvailable"]
        res = call(s, BettingAPI, "listCurrentOrders", Dict{String,Any}("recordCount" => requestinc, "fromRecord" => fromidx))
        fromidx += requestinc
        append!(orders, res["currentOrders"])
    end
    return orders
end

end # module
