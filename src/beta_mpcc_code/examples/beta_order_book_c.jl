Obk=Dict{String, Any}()

Obk["Nodes"]=["1","2","3"]

Obk["Periods"]=["1","2"]#,"2","3"]

Obk["Price_range"]=Dict{String,Any}()
Obk["Price_range"]["lower"]=-500
Obk["Price_range"]["upper"]=500


Obk["Orders"]=Dict{String,Any}()


#-
Obk["Orders"]["13"] = Dict{String,Any}()
Obk["Orders"]["13"]["node"] = "1"
Obk["Orders"]["13"]["type"] = "block"

Obk["Orders"]["13"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["13"]["qtity"]["1"] = -20
Obk["Orders"]["13"]["price"] = Dict{String,Any}()
Obk["Orders"]["13"]["price"]["p0"] = 5

Obk["Orders"]["13"]["mar"] = 1
#-



#-
Obk["Orders"]["1"] = Dict{String,Any}()
Obk["Orders"]["1"]["node"] = "1"
Obk["Orders"]["1"]["type"] = "stepwise"

Obk["Orders"]["1"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["1"]["qtity"]["1"] = 100
Obk["Orders"]["1"]["price"] = Dict{String,Any}()
Obk["Orders"]["1"]["price"]["p0"] = 300
#-


#-
Obk["Orders"]["2"] = Dict{String,Any}()
Obk["Orders"]["2"]["node"] = "2"
Obk["Orders"]["2"]["type"] = "stepwise"

Obk["Orders"]["2"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["2"]["qtity"]["1"] = 50

Obk["Orders"]["2"]["price"] = Dict{String,Any}()
Obk["Orders"]["2"]["price"]["p0"] = 300
#-

#-
Obk["Orders"]["3"] = Dict{String,Any}()
Obk["Orders"]["3"]["node"] = "3"
Obk["Orders"]["3"]["type"] = "stepwise"

Obk["Orders"]["3"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["3"]["qtity"]["1"] = 40

Obk["Orders"]["3"]["price"] = Dict{String,Any}()
Obk["Orders"]["3"]["price"]["p0"] = 300
#-


#-
Obk["Orders"]["4"] = Dict{String,Any}()
Obk["Orders"]["4"]["node"] = "1"
Obk["Orders"]["4"]["type"] = "stepwise"

Obk["Orders"]["4"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["4"]["qtity"]["1"] = -200

Obk["Orders"]["4"]["price"] = Dict{String,Any}()
Obk["Orders"]["4"]["price"]["p0"] = 10
#-

#-
Obk["Orders"]["5"] = Dict{String,Any}()
Obk["Orders"]["5"]["node"] = "2"
Obk["Orders"]["5"]["type"] = "stepwise"

Obk["Orders"]["5"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["5"]["qtity"]["1"] = -100

Obk["Orders"]["5"]["price"] = Dict{String,Any}()
Obk["Orders"]["5"]["price"]["p0"] = 20
#-


#-
Obk["Orders"]["6"] = Dict{String,Any}()
Obk["Orders"]["6"]["node"] = "3"
Obk["Orders"]["6"]["type"] = "stepwise"

Obk["Orders"]["6"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["6"]["qtity"]["1"] = -40

Obk["Orders"]["6"]["price"] = Dict{String,Any}()
Obk["Orders"]["6"]["price"]["p0"] = 80
#-
 
#-
Obk["Orders"]["7"] = Dict{String,Any}()
Obk["Orders"]["7"]["node"] = "1"
Obk["Orders"]["7"]["type"] = "stepwise"

Obk["Orders"]["7"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["7"]["qtity"]["2"] = 100
#Obk["Orders"]["7"]["qtity"]["3"] = 100
Obk["Orders"]["7"]["price"] = Dict{String,Any}()
Obk["Orders"]["7"]["price"]["p0"] = 300
#-


#-
Obk["Orders"]["8"] = Dict{String,Any}()
Obk["Orders"]["8"]["node"] = "2"
Obk["Orders"]["8"]["type"] = "stepwise"

Obk["Orders"]["8"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["8"]["qtity"]["2"] = 50
#Obk["Orders"]["8"]["qtity"]["3"] = 50

Obk["Orders"]["8"]["price"] = Dict{String,Any}()
Obk["Orders"]["8"]["price"]["p0"] = 300
#-

#-
Obk["Orders"]["9"] = Dict{String,Any}()
Obk["Orders"]["9"]["node"] = "3"
Obk["Orders"]["9"]["type"] = "stepwise"

Obk["Orders"]["9"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["9"]["qtity"]["2"] = 40
#Obk["Orders"]["9"]["qtity"]["3"] = 40

Obk["Orders"]["9"]["price"] = Dict{String,Any}()
Obk["Orders"]["9"]["price"]["p0"] = 300
#-


#-
Obk["Orders"]["10"] = Dict{String,Any}()
Obk["Orders"]["10"]["node"] = "1"
Obk["Orders"]["10"]["type"] = "stepwise"

Obk["Orders"]["10"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["10"]["qtity"]["2"] = -200
#Obk["Orders"]["10"]["qtity"]["3"] = -200

Obk["Orders"]["10"]["price"] = Dict{String,Any}()
Obk["Orders"]["10"]["price"]["p0"] = 10
#-

#
Obk["Orders"]["11"] = Dict{String,Any}()
Obk["Orders"]["11"]["node"] = "2"
Obk["Orders"]["11"]["type"] = "stepwise"

Obk["Orders"]["11"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["11"]["qtity"]["2"] = -100
#Obk["Orders"]["11"]["qtity"]["3"] = -100


Obk["Orders"]["11"]["price"] = Dict{String,Any}()
Obk["Orders"]["11"]["price"]["p0"] = 20
#-


#-
Obk["Orders"]["12"] = Dict{String,Any}()
Obk["Orders"]["12"]["node"] = "3"
Obk["Orders"]["12"]["type"] = "stepwise"

Obk["Orders"]["12"]["qtity"] = Dict{String,Any}()
Obk["Orders"]["12"]["qtity"]["2"] = -40
#Obk["Orders"]["12"]["qtity"]["3"] = -40

Obk["Orders"]["12"]["price"] = Dict{String,Any}()
Obk["Orders"]["12"]["price"]["p0"] = 80
#-



#-
Obk["ATC"]=Dict{String, Any}()
Obk["ATC"]["Flows"]=Dict{String, Any}()

Obk["ATC"]["Flows"]["f12"]=Dict{String, Any}()
Obk["ATC"]["Flows"]["f12"]["from"]="1"
Obk["ATC"]["Flows"]["f12"]["to"]="2"

Obk["ATC"]["Flows"]["f13"]=Dict{String, Any}()
Obk["ATC"]["Flows"]["f13"]["from"]="1"
Obk["ATC"]["Flows"]["f13"]["to"]="3"

Obk["ATC"]["Flows"]["f23"]=Dict{String, Any}()
Obk["ATC"]["Flows"]["f23"]["from"]="2"
Obk["ATC"]["Flows"]["f23"]["to"]="3"
#-



Obk["ATC"]["LmTs"]=Dict{String, Any}()

Obk["ATC"]["LmTs"]["test1"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["test1"]["incidence"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["test1"]["incidence"]["f12"]=1
Obk["ATC"]["LmTs"]["test1"]["incidence"]["f13"]=1
Obk["ATC"]["LmTs"]["test1"]["incidence"]["f23"]=0
Obk["ATC"]["LmTs"]["test1"]["value"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["test1"]["value"]["1"]=80





Obk["ATC"]["LmTs"]["lim2"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim2"]["incidence"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim2"]["incidence"]["f12"]=0
Obk["ATC"]["LmTs"]["lim2"]["incidence"]["f13"]=1
Obk["ATC"]["LmTs"]["lim2"]["incidence"]["f23"]=1
Obk["ATC"]["LmTs"]["lim2"]["value"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim2"]["value"]["2"]=35
#Obk["ATC"]["LmTs"]["lim2"]["value"]["3"]=35


Obk["ATC"]["LmTs"]["lim3"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim3"]["incidence"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim3"]["incidence"]["f12"]=0
Obk["ATC"]["LmTs"]["lim3"]["incidence"]["f13"]=0
Obk["ATC"]["LmTs"]["lim3"]["incidence"]["f23"]=1
Obk["ATC"]["LmTs"]["lim3"]["value"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim3"]["value"]["2"]=10
#Obk["ATC"]["LmTs"]["lim3"]["value"]["3"]=10


Obk["ATC"]["LmTs"]["lim4"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim4"]["incidence"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim4"]["incidence"]["f12"]=0
Obk["ATC"]["LmTs"]["lim4"]["incidence"]["f13"]=0
Obk["ATC"]["LmTs"]["lim4"]["incidence"]["f23"]=-1
Obk["ATC"]["LmTs"]["lim4"]["value"]=Dict{String, Any}()
Obk["ATC"]["LmTs"]["lim4"]["value"]["2"]=60
#Obk["ATC"]["LmTs"]["lim4"]["value"]["3"]=60

#------------------------------------------------------




