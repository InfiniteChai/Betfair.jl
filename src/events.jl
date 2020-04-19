export competition, competitions, competitionevents, event

const EVENT_TYPE_OVERRIDES = Dict(:football => :soccer)

function eventtypes(s::Session; refresh::Bool = false)
    if s.state.eventtypes === nothing || refresh
        res = call(s, BettingAPI, "listEventTypes", Dict{String,Any}("filter" => Dict{String,Any}()))
        types = Dict(symbolise(x["eventType"]["name"]) => x["eventType"]["id"] for x in res)
        for (k,v) in EVENT_TYPE_OVERRIDES
            types[k] = types[v]
        end
        s.state.eventtypes = types
    end
    return s.state.eventtypes
end

competition(s::Session, name::String) = get!(s.state.competitions, name) do
    params = Dict{String,Any}("filter" => Dict{String,Any}("textQuery" => name))
    res = call(s, BettingAPI, "listCompetitions", params)
    res = map(x -> unwrap(x, Competition), res)
    res = Dict(map(x -> x.name, res) .=> res)
    res[name]
end

function competitions(s::Session, eventtype::Symbol; refresh::Bool = false)
    if !haskey(s.state.competitionsbytype, eventtype) || refresh
        eventtypeid = eventtypes(s)[eventtype]
        res = call(s, BettingAPI, "listCompetitions", Dict{String,Any}("filter" => Dict{String,Any}("eventTypeIds" => [eventtypeid])))
        res = map(x -> unwrap(x, Competition), res)
        res = Dict(x.name => x for x in res)
        s.state.competitionsbytype[eventtype] = res
        for (name,comp) in res
            s.state.competitions[name] = comp
        end
    end

    return s.state.competitionsbytype[eventtype]
end

competitionevents(s::Session, eventtype::Symbol, competition::String) = competitionevents(s, competitions(s, eventtype)[competition])

function competitionevents(s::Session, comp::Competition)
    res = call(s, BettingAPI, "listEvents", Dict{String,Any}("filter" => Dict{String,Any}("competitionIds" => [comp.id])))
    res = map(x -> unwrap(x, Event), res)
    res = Dict(x.name => x for x in res)
    # We record the events
    for (name,event) in res
        s.state.events[name] = event
    end

    return res
end

event(s::Session, name::String) = get!(s.state.events, name) do
    params = Dict{String,Any}("filter" => Dict{String,Any}("textQuery" => name))
    res = call(s, BettingAPI, "listEvents", params)
    res = map(x -> unwrap(x, Event), res)
    res = Dict(x.name => x for x in res)
    res[name]
end
