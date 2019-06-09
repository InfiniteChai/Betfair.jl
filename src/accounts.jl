struct AccountFunds
    balance::Float64
end

function accountfunds(s::Session)
    res = call(s, AccountsAPI, "getAccountFunds", Dict())
    AccountFunds(res["availableToBetBalance"])
end
