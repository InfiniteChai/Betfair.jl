export accountfunds, accountdetails, accountstatement

accountfunds(s::Session) = call(s, AccountsAPI, "getAccountFunds", Dict{String,Any}())
accountdetails(s::Session) = call(s, AccountsAPI, "getAccountDetails", Dict{String,Any}())
accountstatement(s::Session) = call(s, AccountsAPI, "getAccountStatement", Dict{String,Any}())
