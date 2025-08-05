Obk=Dict{String, Any}()

Obk["Nodes"]=["1"]

Obk["Periods"]=["1"]#,"2","3"]

Obk["Price_range"]=Dict{String,Any}()
Obk["Price_range"]["lower"]=-500
Obk["Price_range"]["upper"]=500


Obk["Orders"]=Dict{String,Any}()

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
Obk["Orders"]["C"]["type"] = "block"

Obk["Orders"]["C"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["C"]["qtity"]["1"] = -12

Obk["Orders"]["C"]["price"] = Dict{String,Any}()
Obk["Orders"]["C"]["price"]["p0"] = 40

Obk["Orders"]["C"]["mar"] = 11/12
#-

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




