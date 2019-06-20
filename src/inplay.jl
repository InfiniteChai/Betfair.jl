struct FootballInPlayState
    score::Tuple{Int64,Int64}
    elapsedtime::Int64
    regulartime::Int64
end

# We should clean this up to have two separate states... Signal needs to be designed to handle both
struct FootballEventState
    inplay::Bool
    minstokickoff::Union{Nothing,Int64}
    inplaystate::Union{Nothing,FootballInPlayState}
end

inplaytimeline(s::Session, key::EventKey) = inplaytimeline(s, event(s, key))

function inplaytimeline(s::Session, event::FootballEvent)
    res = HTTP.request("GET", "https://ips.betfair.com/inplayservice/v1/eventTimeline?alt=json&eventId=$(event.key.id)&locale=en_GB&productType=EXCHANGE&regionCode=UK")
    body = JSON.Parser.parse(String(res.body))
    length(body) != 0 || return FootballEventState(false, round(event.startime - Dates.now(Dates.UTC), Dates.Minute).value, nothing)

    score = (parse(Int8, body["score"]["home"]["score"]), parse(Int8, body["score"]["away"]["score"]))
    FootballEventState(true, nothing, FootballInPlayState(score,body["timeElapsed"],body["elapsedRegularTime"]))
end

function inplaytimeline(s::Session, event::CricketEvent)
    res = HTTP.request("GET", "https://ips.betfair.com/inplayservice/v1/scores?_ak=nzIFcwyWhrlwYMrh&alt=json&eventIds=$(event.key.id)&locale=en_GB&productType=EXCHANGE&regionCode=UK")
    body = JSON.Parser.parse(String(res.body))
    length(body) != 0 || return Dict{String,Any}("inplay" => false)
    gamestate = body[1]
    # We need to know which innings we're in, what the current score is and how many overs there are.
    gamestate["matchType"] == "LIMITED_OVER" || error("No support for cricket matches of type $(gamestate["matchType"])")

    # add the appropriate handling to get team score [what about individuals?
    return gamestate
end
