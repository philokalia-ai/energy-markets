Obk=Dict{String, Any}()
Obk["Name"]="MOB"
Obk["Nodes"]=["1"]

Obk["Periods"]=["1"]#,"2","3"]

Obk["Price_range"]=Dict{String,Any}()
Obk["Price_range"]["lower"]=-500
Obk["Price_range"]["upper"]=500


Obk["Orders"]=Dict{String,Any}()
Obk["ComplexOrders"]=Dict{String,Any}()
#-
Obk["Orders"]["A"] = Dict{String,Any}()
Obk["Orders"]["A"]["node"] = "1"
Obk["Orders"]["A"]["type"] = "stepwise"

Obk["Orders"]["A"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["A"]["qtity"]["1"] = 10
Obk["Orders"]["A"]["price"] = Dict{String,Any}()
Obk["Orders"]["A"]["price"]["p0"] = 300
#-


#-
Obk["Orders"]["B"] = Dict{String,Any}()
Obk["Orders"]["B"]["node"] = "1"
Obk["Orders"]["B"]["type"] = "stepwise"

Obk["Orders"]["B"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["B"]["qtity"]["1"] = 14

Obk["Orders"]["B"]["price"] = Dict{String,Any}()
Obk["Orders"]["B"]["price"]["p0"] = 10
#-

#-
Obk["Orders"]["C"] = Dict{String,Any}()
Obk["Orders"]["C"]["node"] = "1"
Obk["Orders"]["C"]["type"] = "linked"

Obk["Orders"]["C"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["C"]["qtity"]["1"] = -12

Obk["Orders"]["C"]["price"] = Dict{String,Any}()
Obk["Orders"]["C"]["price"]["p0"] = 40

Obk["Orders"]["C"]["mar"] = 11/12
#-


#-
Obk["Orders"]["C2"] = Dict{String,Any}()
Obk["Orders"]["C2"]["node"] = "1"
Obk["Orders"]["C2"]["type"] = "linked"

Obk["Orders"]["C2"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["C2"]["qtity"]["1"] = -2

Obk["Orders"]["C2"]["price"] = Dict{String,Any}()
Obk["Orders"]["C2"]["price"]["p0"] =8

Obk["Orders"]["C2"]["mar"] = 0.5
#-

#=
#-
Obk["Orders"]["C3"] = Dict{String,Any}()
Obk["Orders"]["C3"]["node"] = "1"
Obk["Orders"]["C3"]["type"] = "linked"

Obk["Orders"]["C3"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["C3"]["qtity"]["1"] = -12

Obk["Orders"]["C3"]["price"] = Dict{String,Any}()
Obk["Orders"]["C3"]["price"]["p0"] = 20

Obk["Orders"]["C3"]["mar"] = 0
#-
=#


Obk["ComplexOrders"]["FAM1"]=Dict{String,Any}()
Obk["ComplexOrders"]["FAM1"]["type"]="linked"
Obk["ComplexOrders"]["FAM1"]["parent"]="C"
Obk["ComplexOrders"]["FAM1"]["children"]=["C2"]



#-
Obk["Orders"]["D"] = Dict{String,Any}()
Obk["Orders"]["D"]["node"] = "1"
Obk["Orders"]["D"]["type"] = "stepwise"

Obk["Orders"]["D"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["D"]["qtity"]["1"] = -13
Obk["Orders"]["D"]["price"] = Dict{String,Any}()
Obk["Orders"]["D"]["price"]["p0"] = 100
#-
 

 
Obk["ATC"]=Dict{String,Any}()

Obk["ATC"]["Flows"]=Dict{String,Any}()
 
 

 


 

#------------------------------------------------------




