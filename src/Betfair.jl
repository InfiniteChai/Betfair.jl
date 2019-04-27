module Betfair

using HTTP
using JSON
import Dates
using Pkg.TOML
import Memoize

abstract type API end
struct BettingAPI <: API end
full_method(::Type{BettingAPI}, method::String) = "SportsAPING/v1.0/$(method)"
endpoint(::Type{BettingAPI}) = "https://api.betfair.com/exchange/betting/json-rpc/v1"

struct AccountsAPI <: API end
full_method(::Type{AccountsAPI}, method::String) = "AccountsAPING/v1.0/$(method)"
endpoint(::Type{AccountsAPI}) = "https://api.betfair.com/exchange/account/json-rpc/v1"

mutable struct Session
    msgid::Int32
    token::Union{Nothing,String}
    appid::String

    Session(appid::String) = new(0, nothing, appid)
end

function headers(s::Session; accept = "application/json", content = "application/json") :: Dict{String, String}
    headers = Dict("Accept" => accept, "Content-Type" => content, "X-Application" => s.appid)
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
    body = JSON.Parser.parse(String(result.body))
    !haskey(body, "error") || throw(error("Failed to call $(method) with code $(body["error"]["code"])"))
    return body["result"]
end

getAccountFunds(s::Session) = call(s, AccountsAPI, "getAccountFunds", Dict{String,Any}())
getAccountDetails(s::Session) = call(s, AccountsAPI, "getAccountDetails", Dict{String,Any}())
getAccountStatement(s::Session) = call(s, AccountsAPI, "getAccountStatement", Dict{String,Any}())

# Some specific overrides to standard terminology for
const eventTypeOverrides = Dict{String, String}("Football" => "Soccer")

Memoize.@memoize function listEventTypes(s::Session)
    res = call(s, BettingAPI, "listEventTypes", Dict{String,Any}("filter" => Dict{String,Any}()))
    types = Dict(map(x->x["eventType"]["name"], res) .=> map(x->x["eventType"]["id"], res))
    for (k,v) in eventTypeOverrides
        types[k] = types[v]
    end

    return types
end

function extendedEventType(event)
    return Dict("openDateTime" => Dates.parse(Dates.DateTime, event["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ")))
end

function listEvents(s::Session, event::String)
    eventtypes = listEventTypes(s)
    res = call(s, BettingAPI, "listEvents", Dict{String,Any}("filter" => Dict{String,Any}("eventTypeIds" => [eventtypes[event]])))
    events = Dict(map(x->x["event"]["id"], res) .=> map(x->merge(extendedEventType(x["event"]),x["event"]), res))
    return events
end

function listCurrentOrders(s::Session; requestinc = 1000)
    res = call(s, BettingAPI, "listCurrentOrders", Dict{String,Any}("recordCount" => requestinc))
    orders = res["currentOrders"]; fromidx = requestinc;
    while res["moreAvailable"]
        res = call(s, BettingAPI, "listCurrentOrders", Dict{String,Any}("recordCount" => requestinc, "fromRecord" => fromidx))
        fromidx += requestinc
        append!(orders, res["currentOrders"])
    end
    return orders
end

function initsession()
    settings = TOML.parsefile("cfg\\settings.toml")
    s = Betfair.Session(settings["account"]["appid"])
    Betfair.connect(s, settings["account"]["username"], settings["account"]["password"])
    return s
end

end # module
