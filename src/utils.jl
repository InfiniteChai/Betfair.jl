function symbolise(s::String)
    return split(s) |> (x -> map(lowercase, x)) |> (x -> join(x, "_")) |> (x -> Symbol(x))
end

symbolisekeys(res) = res
symbolisekeys(res::Dict) = Dict(symbolise(k) => v for (k,v) in res)
