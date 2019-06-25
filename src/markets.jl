import Match
import Dates

struct EventKey <: Key
    id::String
end

struct MarketKey <: Key
    id::String
end

struct RunnerKey <: Key
    id::Int64
end

struct CompetitionKey <: Key
    id::String
end

struct Competition
    key::CompetitionKey
    name::String
end

struct Team
    name::String
end

abstract type Event end

mutable struct FootballEvent <: Event
    key::EventKey
    name::String
    hometeam::Team
    awayteam::Team
    _competition::Union{Nothing,CompetitionKey}
    _markets::Union{Nothing,Vector{MarketKey}}
    starttime::Dates.DateTime
    function FootballEvent(key::EventKey, name::String, starttime::Dates.DateTime)
        (home, away) = split(name, " v ")
        new(key, name, Team(home), Team(away), nothing, nothing, starttime)
    end
end

mutable struct CricketEvent <: Event
    key::EventKey
    name::String
    hometeam::Team
    awayteam::Team
    _competition::Union{Nothing,CompetitionKey}
    _markets::Union{Nothing,Vector{MarketKey}}
    starttime::Dates.DateTime
    function CricketEvent(key::EventKey, name::String, starttime::Dates.DateTime)
        (home, away) = split(name, " v ")
        new(key, name, Team(home), Team(away), nothing, nothing, starttime)
    end
end

struct Runner
    key::RunnerKey
    name::String
end

struct Market
    key::MarketKey
    name::String
    event::EventKey
    runners::Dict{RunnerKey, Runner}
end

const EVENT_TYPE_OVERRIDES = Dict(:football => :soccer)

function listeventtypes(s::Session)
    if s.eventtypes === nothing
        res = call(s, BettingAPI, "listEventTypes", Dict("filter" => Dict()))
        types = Dict(map(x->Symbol(replace(lowercase(x["eventType"]["name"]), " " => "_")), res) .=> map(x->x["eventType"]["id"], res))
        for (k,v) in EVENT_TYPE_OVERRIDES
            types[k] = types[v]
        end

        s.eventtypes = types
    end

    return s.eventtypes
end

function parseevent(event, eventtype::Symbol)
    Match.@match eventtype begin
        :football || :soccer => begin
            starttime = Dates.parse(Dates.DateTime, event["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ"))
            FootballEvent(EventKey(event["id"]), event["name"], starttime)
        end
        :cricket => begin
            starttime = Dates.parse(Dates.DateTime, event["openDate"], Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS.sZ"))
            CricketEvent(EventKey(event["id"]), event["name"], starttime)
        end
        _ => error("Unable to handle event type $(eventtype)")
    end
end

event(s::Session, market::Market) = event(s, market.event)
event(s::Session, key::MarketKey) = event(s, market(s, key))

function event(s::Session, key::EventKey)
    get!(s.cache, key) do
        params = Dict(
            "filter" => Dict("eventIds" => [key.id]),
            "marketProjection" => ["COMPETITION", "EVENT", "EVENT_TYPE", "MARKET_START_TIME", "MARKET_DESCRIPTION", "RUNNER_DESCRIPTION"],
            "maxResults" => 1000
        )

        markets = call(s, BettingAPI, "listMarketCatalogue", params)
        length(markets) > 0 || error("no markets found for event $(key.id)")
        # First parse the event
        eventinfo = markets[1]["event"]
        eventtype = Symbol(lowercase(markets[1]["eventType"]["name"]))
        event = parseevent(eventinfo, eventtype)

        # Now the competition
        c = Competition(CompetitionKey(markets[1]["competition"]["id"]), markets[1]["competition"]["name"])
        event._competition = c.key
        s.cache[c.key] = c

        # Now parse each of the markets
        marketkeys = []
        for market in markets
            marketkey = MarketKey(market["marketId"])
            runners = Dict{RunnerKey,Runner}()
            for runner in market["runners"]
                r = Runner(RunnerKey(runner["selectionId"]), runner["runnerName"])
                runners[r.key] = r
            end
            m = Market(marketkey, market["marketName"], key, runners)
            push!(marketkeys, m.key)


            s.cache[m.key] = m
        end
        event._markets = marketkeys
        event
    end
end

function markets(s::Session, key::EventKey)
    markets(s, event(s, key))
end

function markets(s::Session, event::Event)
    event._markets !== nothing || error("Need to handle case where _markets not defined")
    Dict(zip(event._markets, map(k -> market(s, k), event._markets)))
end

function marketsbyname(s::Session, key::EventKey)
    marketsbyname(s, event(s, key))
end

function marketsbyname(s::Session, event::Event)
    event._markets !== nothing || error("Need to handle case where _markets not defined")
    markets = map(k -> market(s, k), event._markets)
    Dict(zip(map(m -> m.name, markets), markets))
end

function market(s::Session, key::MarketKey)
    get!(s.cache, key) do
        params = Dict(
            "filter" => Dict("marketIds" => [key.id]),
            "marketProjection" => ["COMPETITION", "EVENT", "EVENT_TYPE", "MARKET_START_TIME", "MARKET_DESCRIPTION", "RUNNER_DESCRIPTION"],
            "maxResults" => 1000
        )

        markets = call(s, BettingAPI, "listMarketCatalogue", params)
        length(markets) == 1 || error("expect only one market for $(key.id), found $(length(markets))")
        market = markets[1]
        marketkey = MarketKey(market["marketId"])
        eventkey = EventKey(market["event"]["id"])
        runners = Dict{RunnerKey,Runner}()
        for runner in market["runners"]
            r = Runner(RunnerKey(runner["selectionId"]), runner["runnerName"])
            runners[r.key] = r
        end
        m = Market(marketkey, market["marketName"], eventkey, runners)
        m
    end
end

runners(s::Session, key::MarketKey) = runners(s, market(s, key))
runners(s::Session, market::Market) = market.runners

runnersbyname(s::Session, key::MarketKey) = runnersbyname(s, market(s, key))
function runnersbyname(s::Session, market::Market)
    rs = values(market.runners)
    Dict(zip(map(r -> r.name, rs), rs))
end

marketrunner(s::Session, key::EventKey, marketname::String, runnername::String) =
    marketrunner(s, event(s, key), marketname, runnername)
function marketrunner(s::Session, event::Event, marketname::String, runnername::String)
    market = marketsbyname(s, event)[marketname]
    runner = runnersbyname(s, market)[runnername]
    return market, runner
end
