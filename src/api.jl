export init, initfromfile

function init(appid::String, username::String, password::String)
    s = Betfair.Session(appid)
    Betfair.connect(s, username, password)
    return s
end

function initfromfile(; filename::String = "cfg\\settings.toml")
    settings = TOML.parsefile(filename)
    return init(settings["account"]["appid"], settings["account"]["username"], settings["account"]["password"])
end

abstract type API end
struct BettingAPI <: API end
full_method(::Type{BettingAPI}, method::String) = "SportsAPING/v1.0/$(method)"
endpoint(::Type{BettingAPI}) = "https://api.betfair.com/exchange/betting/json-rpc/v1"

struct AccountsAPI <: API end
full_method(::Type{AccountsAPI}, method::String) = "AccountAPING/v1.0/$(method)"
endpoint(::Type{AccountsAPI}) = "https://api.betfair.com/exchange/account/json-rpc/v1"


mutable struct SessionState
    eventtypes::Union{Nothing,Dict{Symbol,String}}
    competitions::Dict{String,Competition}
    competitionsbytype::Dict{Symbol,Dict{String,Competition}}
    events::Dict{String,Event}
    markets::Dict{String,Market}
    marketsbyevent::Dict{String,Vector{Market}}
    SessionState() = new(nothing, Dict(), Dict(), Dict(), Dict(), Dict())
end

mutable struct Session
    msgid::Int32
    token::Union{Nothing,String}
    appid::String
    state::SessionState

    Session(appid::String) = new(0, nothing, appid, SessionState())
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
    return symbolisekeys(body["result"])
end
