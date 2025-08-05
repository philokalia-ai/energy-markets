#------------------------------------------------------------------------------------------#
using JuMP, Ipopt, Suppressor,JSON, Plots, ProgressBars, CSV, TickTock,  Complementarity, CPLEX
using Plots.PlotMeasures

ENV["TICKTOCK_MESSAGES"] = false
#------------------------------------------------------------------------------------------#

include("..//examples//beta_order_book_cexl.jl")



#-- data organization shortcuts (key collections) -----------------------------------------#
stepwise_orders=filter((k, v)::Pair  ->  v["type"] == "stepwise", Obk["Orders"]) |> keys

block_orders=filter((k, v)::Pair  ->  (v["type"] == "block" || v["type"]=="exclusive" || v["type"]=="linked"), Obk["Orders"]) |> keys

ex_block_orders=filter((k, v)::Pair  ->  v["type"] =="exclusive", Obk["Orders"]) |> keys
lnkd_block_orders=filter((k, v)::Pair  ->  v["type"] =="linked", Obk["Orders"]) |> keys

ex_order_groups=filter((k, v)::Pair  ->  v["type"] =="exclusive", Obk["ComplexOrders"]) |> keys
lnkd_order_groups=filter((k, v)::Pair  ->  v["type"] =="linked", Obk["ComplexOrders"]) |> keys
 
parents=String[]
children=String[]
for gdx in lnkd_order_groups
    push!(parents,Obk["ComplexOrders"][gdx]["parent"])
    for cdx in Obk["ComplexOrders"][gdx]["children"]
        push!(children,cdx)
    end
end

nodal_keys=Dict{String,Any}()
for ndx in Obk["Nodes"]

    nodal_keys[ndx]=Dict{String,Any}()
    nodal_keys[ndx]["stepwise_orders"]=Dict{String,Any}()
    for tdx in Obk["Periods"]
        nodal_keys[ndx]["stepwise_orders"][tdx]= filter((k, v)::Pair  ->  v["type"] == "stepwise" && v["node"]==ndx && haskey(v["qtity"],tdx)    , Obk["Orders"]) |> keys
    end

    nodal_keys[ndx]["block_orders"]=Dict{String,Any}()
    for tdx in Obk["Periods"]
        nodal_keys[ndx]["block_orders"][tdx]= filter((k, v)::Pair  ->  (v["type"] == "block" || v["type"]=="exclusive" || v["type"]=="linked") && v["node"]==ndx && haskey(v["qtity"],tdx)    , Obk["Orders"]) |> keys
    end


    if haskey(Obk["ATC"],"Flows")
        nodal_keys[ndx]["flows_from"]=filter((k, v)::Pair  ->  v["from"] == ndx    , Obk["ATC"]["Flows"]) |> keys
        nodal_keys[ndx]["flows_to"]=filter((k, v)::Pair  ->  v["to"] == ndx    , Obk["ATC"]["Flows"]) |> keys
    end
end



if haskey(Obk["ATC"],"LmTs")
    limit_keys=Dict{String,Any}()
    for tdx in Obk["Periods"]
        limit_keys[tdx]=filter((k, v)::Pair  ->  haskey(v["value"],tdx), Obk["ATC"]["LmTs"]) |> keys
    end
end
#------------------------------------------------------------------------------------------#


#-- mpcc model -----------------------------------------------------------------------------#
mpcc_sxl_mdl = Model(CPLEX.Optimizer)
#MOI.set(mpcc_sxl_mdl, MOI.Silent(), true)

BigMe=4000000

#-[stepwise order acceptance]: primal variables & dual variables
@variable(mpcc_sxl_mdl,0<=x[idx in stepwise_orders]) 
@variable(mpcc_sxl_mdl,0<=xsw[idx in stepwise_orders]) 
#--

#-[block order acceptance]: primal & dual variables
@variable(mpcc_sxl_mdl,0<=y[idx in block_orders],Bin) 
@variable(mpcc_sxl_mdl,0<=xb[idx in block_orders])         # M4c
@variable(mpcc_sxl_mdl,0<=xb_low[idx in block_orders])         # M4c
@variable(mpcc_sxl_mdl,0<=xb_upp[idx in block_orders])         # M4c


@variable(mpcc_sxl_mdl,0<=ysw[idx in block_orders; (!(idx in ex_block_orders) && !(idx in children))])  ## modified 
@variable(mpcc_sxl_mdl,0<=yexsw[idx in ex_order_groups])  ## modified 
@variable(mpcc_sxl_mdl,0<=ylnkd[idx in lnkd_order_groups, cdx in Obk["ComplexOrders"][idx]["children"]])  ## new
#-

#-[ATC flow]: primal variables
if haskey(Obk["ATC"],"Flows")
    @variable(mpcc_sxl_mdl,atc_flow[idx in keys(Obk["ATC"]["Flows"]),tdx in Obk["Periods"]]) #-- ATC flow x(time periods)
end
#--


#-[(nodal) power balance]: dual variables
@variable(mpcc_sxl_mdl,mu[ndx in Obk["Nodes"], tdx in Obk["Periods"]])
#-


#-[stepwise order acceptance]: primal & dual constraints
@constraint(mpcc_sxl_mdl, xvar_upper[idx in stepwise_orders],
    x[idx] <= 1
)

@expression(mpcc_sxl_mdl, xvar_rhs[idx in stepwise_orders], #- dual constraint right-hand-side
    xsw[idx]
    +
    sum(Obk["Orders"][idx]["qtity"][tdx] * mu[Obk["Orders"][idx]["node"], tdx] for tdx in keys(Obk["Orders"][idx]["qtity"]))
    -
    sum(Obk["Orders"][idx]["qtity"][tdx] * Obk["Orders"][idx]["price"]["p0"] for tdx in keys(Obk["Orders"][idx]["qtity"]))
)

@constraint(mpcc_sxl_mdl, xvar_dual_cstr[idx in stepwise_orders],
    0 <=
    xvar_rhs[idx]
)
#--

#-[block order activation]: primal constraints
@constraint(mpcc_sxl_mdl, block_order_upper[idx in block_orders; (!(idx in ex_block_orders) && !(idx in children))],
    y[idx] <= 1
)
#--

#-[block order aceptance]: primal constraints #(M4C)
@constraint(mpcc_sxl_mdl, block_order_xupper[idx in block_orders], 
    xb[idx] <= y[idx]
)

@constraint(mpcc_sxl_mdl, block_order_lower[idx in block_orders],  
Obk["Orders"][idx]["mar"]*y[idx] <= xb[idx]
)
#--

#-[exclusive block order groups]: primal constraint
@constraint(mpcc_sxl_mdl,ex_group[idx in ex_order_groups],
    sum(y[odx] for odx in Obk["ComplexOrders"][idx]["members"])<=1
)
#--

#-[linked block order group]: primal constraint
@constraint(mpcc_sxl_mdl,lnkd_group[idx in lnkd_order_groups,jdx in Obk["ComplexOrders"][idx]["children"]],
    y[jdx]<=y[Obk["ComplexOrders"][idx]["parent"]]
)
#--

#-[block order aceptance]: dual constraint (M4C)
@expression(mpcc_sxl_mdl, xbvar_rhs[idx in block_orders], 
    xb_upp[idx]-xb_low[idx]
    +
    sum(Obk["Orders"][idx]["qtity"][tdx] * mu[Obk["Orders"][idx]["node"], tdx] for tdx in keys(Obk["Orders"][idx]["qtity"]))
    -
    sum(Obk["Orders"][idx]["qtity"][tdx] * Obk["Orders"][idx]["price"]["p0"] for tdx in keys(Obk["Orders"][idx]["qtity"]))
)
@constraint(mpcc_sxl_mdl, xbvar_dual_cstr[idx in block_orders],        #(M4C)
    0 <=
    xbvar_rhs[idx]
)
#--

#-[block order activation]: dual constraint -- REGULAR BLOCKS ONLY (M4C)
@expression(mpcc_sxl_mdl, yvar_rhs[idx in block_orders; (!(idx in ex_block_orders) && !(idx in lnkd_block_orders))],
    ysw[idx]
    +Obk["Orders"][idx]["mar"]*xb_low[idx]-xb_upp[idx] 
)
@constraint(mpcc_sxl_mdl, yvar_dual_cstr[idx in block_orders; (!(idx in ex_block_orders) && !(idx in lnkd_block_orders))],
    0 <=
    yvar_rhs[idx]
)
#--

#-[block order activation]: dual constraint -- EXCLUSIVE BLOCKS ONLY (M4C)
@expression(mpcc_sxl_mdl, yexvar_rhs[idx in ex_block_orders], 
    sum(yexsw[gdx] for gdx in ex_order_groups if idx in Obk["ComplexOrders"][gdx]["members"]) 
    +Obk["Orders"][idx]["mar"]*xb_low[idx]-xb_upp[idx] 
)
@constraint(mpcc_sxl_mdl, yexvar_dual_cstr[idx in ex_block_orders],
    0 <=
    yexvar_rhs[idx]
)
#--

#-[block order activation]: dual constraint -- PARENT BLOCKS ONLY (M4C)
@expression(mpcc_sxl_mdl, ypar_rhs[idx in parents], 
    ysw[idx]
    -sum(sum(ylnkd[gdx,cdx] for cdx in Obk["ComplexOrders"][gdx]["children"]) for gdx in lnkd_order_groups if idx==Obk["ComplexOrders"][gdx]["parent"]) 
    +Obk["Orders"][idx]["mar"]*xb_low[idx]-xb_upp[idx] 
)
@constraint(mpcc_sxl_mdl, ypar_dual_cstr[idx in parents],
    0 <=
    ypar_rhs[idx]
)
#--

#-[block order activation]: dual constraint -- CHILD BLOCKS ONLY (M4C)
@expression(mpcc_sxl_mdl, ychild_rhs[idx in children], 
    sum(ylnkd[gdx,idx] for gdx in lnkd_order_groups if idx in Obk["ComplexOrders"][gdx]["children"]) 
    +Obk["Orders"][idx]["mar"]*xb_low[idx]-xb_upp[idx] 
)
@constraint(mpcc_sxl_mdl, ychild_dual_cstr[idx in children],
    0 <=
    ychild_rhs[idx]
)
#--

#-[stepwise order acceptance]: complementarity constraints
@variable(mpcc_sxl_mdl,aux_x[idx in stepwise_orders],Bin)
@variable(mpcc_sxl_mdl,aux_xsw[idx in stepwise_orders],Bin)

@constraint(mpcc_sxl_mdl,comp_x_ineq1[idx in stepwise_orders],    x[idx]<=aux_x[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_x_ineq2[idx in stepwise_orders],    xvar_rhs[idx]<=(1-aux_x[idx])*BigMe)

@constraint(mpcc_sxl_mdl,comp_xsw_ineq1[idx in stepwise_orders],xsw[idx]<=aux_xsw[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_xsw_ineq2[idx in stepwise_orders],x[idx]-1>=(aux_xsw[idx]-1)*BigMe)
#--

#-[block order activation]: complementarity constraints
@variable(mpcc_sxl_mdl,aux_y[idx in block_orders; (!(idx in ex_block_orders) && !(idx in lnkd_block_orders))],Bin)  #-- not for blocks in complex groups
@constraint(mpcc_sxl_mdl,comp_y_ineq1[idx in block_orders; (!(idx in ex_block_orders) && !(idx in lnkd_block_orders))],    y[idx]<=aux_y[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_y_ineq2[idx in block_orders; (!(idx in ex_block_orders) && !(idx in lnkd_block_orders))],    yvar_rhs[idx]<=(1-aux_y[idx])*BigMe)

#-[exclusive block order group welfare]: complementarity constraints
@variable(mpcc_sxl_mdl,aux_yex[idx in ex_block_orders],Bin)  #--  blocks in exclusive groups
@constraint(mpcc_sxl_mdl,comp_yex_ineq1[idx in ex_block_orders],    y[idx]<=aux_yex[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_yex_ineq2[idx in ex_block_orders],    yexvar_rhs[idx]<=(1-aux_yex[idx])*BigMe) 

@variable(mpcc_sxl_mdl,aux_ex_groups[idx in ex_order_groups],Bin)  #--  blocks in exclusive groups
@constraint(mpcc_sxl_mdl,comp_aux_ex_groups_ineq1[idx in ex_order_groups],    yexsw[idx]<=aux_ex_groups[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_aux_ex_groups_ineq2[idx in ex_order_groups],    1- sum(y[odx] for odx in Obk["ComplexOrders"][idx]["members"])<=(1-aux_ex_groups[idx])*BigMe)

#-[linked block order group welfare]: complementarity constraints
@variable(mpcc_sxl_mdl,aux_ypar[idx in parents],Bin)  #--  parent blocks
@constraint(mpcc_sxl_mdl,comp_ypar_ineq1[idx in parents],    y[idx]<=aux_ypar[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_ypar_ineq2[idx in parents],    ypar_rhs[idx]<=(1-aux_ypar[idx])*BigMe)

@variable(mpcc_sxl_mdl,aux_ychild[idx in children],Bin)  #--  children blocks
@constraint(mpcc_sxl_mdl,comp_ychild_ineq1[idx in children],    y[idx]<=aux_ychild[idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_ychild_ineq2[idx in children],    ychild_rhs[idx]<=(1-aux_ychild[idx])*BigMe)

@variable(mpcc_sxl_mdl,aux_lnkd[gdx in lnkd_order_groups,idx in Obk["ComplexOrders"][gdx]["children"]],Bin)
@constraint(mpcc_sxl_mdl,comp_lnkd_group_ineq1[gdx in lnkd_order_groups,idx in Obk["ComplexOrders"][gdx]["children"]], ylnkd[gdx,idx]<=aux_lnkd[gdx,idx]*BigMe)
@constraint(mpcc_sxl_mdl,comp_lnkd_group_ineq2[gdx in lnkd_order_groups,idx in Obk["ComplexOrders"][gdx]["children"]], y[Obk["ComplexOrders"][gdx]["parent"]]-y[idx]<=(1-aux_lnkd[gdx,idx])*BigMe)
#--


#-[block order acceptance]: complementarity constraints
@variable(mpcc_sxl_mdl,aux_xb[idx in block_orders],Bin)  #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_ineq1[idx in block_orders],    xb[idx]<=aux_xb[idx]*BigMe)   #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_ineq2[idx in block_orders],    xbvar_rhs[idx]<=(1-aux_xb[idx])*BigMe) #(M4C)

@variable(mpcc_sxl_mdl,aux_xb_low[idx in block_orders],Bin)  #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_low_ineq1[idx in block_orders],    xb_low[idx]<=aux_xb_low[idx]*BigMe)   #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_low_ineq2[idx in block_orders],  xb[idx]-Obk["Orders"][idx]["mar"]*y[idx]<=(1-aux_xb_low[idx])*BigMe) #(M4C)

@variable(mpcc_sxl_mdl,aux_xb_upp[idx in block_orders],Bin)  #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_upp_ineq1[idx in block_orders],    xb_upp[idx]<=aux_xb_upp[idx]*BigMe)   #(M4C)
@constraint(mpcc_sxl_mdl,comp_xb_upp_ineq2[idx in block_orders],   y[idx]-xb[idx]<=(1-aux_xb_upp[idx])*BigMe) #(M4C)
#--

#-[nodal power balance]: primal constraints (M4C)
if haskey(Obk["ATC"], "Flows")
    @constraint(mpcc_sxl_mdl, nodal_pb[ndx in Obk["Nodes"], tdx in Obk["Periods"]], 
        sum(x[idx] * Obk["Orders"][idx]["qtity"][tdx] for idx in nodal_keys[ndx]["stepwise_orders"][tdx])
        +sum(xb[idx] * Obk["Orders"][idx]["qtity"][tdx] for idx in nodal_keys[ndx]["block_orders"][tdx])
        ==
        sum(atc_flow[fdx, tdx] for fdx in nodal_keys[ndx]["flows_to"])
        -
        sum(atc_flow[fdx, tdx] for fdx in nodal_keys[ndx]["flows_from"])
    )
    #- Nb: since supply quantities are negative => inbound flows are also negative (outbound flows are positive in the from --> to direction)
else #- no network
    @constraint(mpcc_sxl_mdl, nodal_pb[ndx in Obk["Nodes"], tdx in Obk["Periods"]],
        sum(x[idx] * Obk["Orders"][idx]["qtity"][tdx] for idx in nodal_keys[ndx]["stepwise_orders"][tdx])
        +sum(xb[idx] * Obk["Orders"][idx]["qtity"][tdx] for idx in nodal_keys[ndx]["block_orders"][tdx])
        ==
        0)
end
#--

#-[network security]: primal constraints
if haskey(Obk["ATC"],"LmTs")

    @expression(mpcc_sxl_mdl, grid_lhs[kdx in keys(Obk["ATC"]["LmTs"]), tdx in Obk["Periods"]; haskey(Obk["ATC"]["LmTs"][kdx]["value"], tdx)],
        sum(atc_flow[fdx, tdx] * Obk["ATC"]["LmTs"][kdx]["incidence"][fdx] for fdx in keys(Obk["ATC"]["Flows"]))
    )

    @constraint(mpcc_sxl_mdl, grid_lim[kdx in keys(Obk["ATC"]["LmTs"]), tdx in Obk["Periods"]; haskey(Obk["ATC"]["LmTs"][kdx]["value"], tdx)],
        grid_lhs[kdx, tdx] <= Obk["ATC"]["LmTs"][kdx]["value"][tdx]
    )
end
#--

#--[network security]: dual variables
if haskey(Obk["ATC"],"LmTs")
    @variable(mpcc_sxl_mdl,0<=lambda[idx in keys(Obk["ATC"]["LmTs"]),tdx  in keys(Obk["ATC"]["LmTs"][idx]["value"])]) #-- security constraint 
end
#--

#--[network security]: complementarity constraints
if haskey(Obk["ATC"], "LmTs")
    @variable(mpcc_sxl_mdl, aux_grid[idx in keys(Obk["ATC"]["LmTs"]), tdx in keys(Obk["ATC"]["LmTs"][idx]["value"])], Bin)

    @constraint(mpcc_sxl_mdl, comp_grid_ineq1[idx in keys(Obk["ATC"]["LmTs"]), tdx in keys(Obk["ATC"]["LmTs"][idx]["value"])],
        lambda[idx, tdx] <= aux_grid[idx, tdx] * BigMe)
    @constraint(mpcc_sxl_mdl, comp_grid_ineq2[idx in keys(Obk["ATC"]["LmTs"]), tdx in keys(Obk["ATC"]["LmTs"][idx]["value"])],
        grid_lhs[idx, tdx] - Obk["ATC"]["LmTs"][idx]["value"][tdx] >= (aux_grid[idx, tdx] - 1) * BigMe)
end
#-

#-[ATC flow]: dual constraints
if haskey(Obk["ATC"],"LmTs")
    @constraint(mpcc_sxl_mdl,atc_flow_var[fdx in keys(Obk["ATC"]["Flows"]),tdx in Obk["Periods"]],
    sum(lambda[sdx,tdx]* Obk["ATC"]["LmTs"][sdx]["incidence"][fdx] for sdx in limit_keys[tdx])
    +mu[Obk["ATC"]["Flows"][fdx]["from"],tdx]
    -mu[Obk["ATC"]["Flows"][fdx]["to"],tdx]
    ==0
    )
else
    @constraint(mpcc_sxl_mdl,atc_flow_var[fdx in keys(Obk["ATC"]["Flows"]),tdx in Obk["Periods"]],
        +mu[Obk["ATC"]["Flows"][fdx]["from"],tdx]
        -mu[Obk["ATC"]["Flows"][fdx]["to"],tdx]
        ==0
    )
end
#--


#-[price range]: constraints
if haskey(Obk,"Price_range")
    @constraint(mpcc_sxl_mdl,lower_price[ndx in Obk["Nodes"], tdx in Obk["Periods"]],mu[ndx,tdx]>=Obk["Price_range"]["lower"])
    @constraint(mpcc_sxl_mdl,upper_price[ndx in Obk["Nodes"], tdx in Obk["Periods"]],mu[ndx,tdx]<=Obk["Price_range"]["upper"])
end



#-- mpcc objective (M4C)
@objective(mpcc_sxl_mdl,Max,
sum(x[idx]*(sum(Obk["Orders"][idx]["qtity"][tdx] for tdx in Obk["Periods"] if haskey(Obk["Orders"][idx]["qtity"],tdx)))*Obk["Orders"][idx]["price"]["p0"]  for idx in stepwise_orders)
+sum(xb[idx]*(sum(Obk["Orders"][idx]["qtity"][tdx] for tdx in Obk["Periods"] if haskey(Obk["Orders"][idx]["qtity"],tdx)))*Obk["Orders"][idx]["price"]["p0"]  for idx in block_orders)
)



#-- solve statements ----------------------------------------------------------------------#
println(mpcc_sxl_mdl)
optimize!(mpcc_sxl_mdl)
#------------------------------------------------------------------------------------------#


#------------------------------------------------------------------------------------------#
println()
println("Welfare:",round(JuMP.objective_value(mpcc_sxl_mdl),digits=3))


println()
println("Stepwise order Acceptance")
for idx in stepwise_orders
println(idx, ": ", round(JuMP.value(x[idx]),digits=3), "/", round(JuMP.value(xsw[idx]),digits=3))
end


println()
println("Block order Acceptance")
for idx in block_orders 
    try
        println(idx, " [", Obk["Orders"][idx]["type"] , "] : ",round(JuMP.value(xb[idx]),digits=3),"<=", round(JuMP.value(y[idx]),digits=3), "/", round(JuMP.value(ysw[idx]),digits=3))
    catch
        if idx in ex_block_orders
           println(idx," [", Obk["Orders"][idx]["type"] , "] : ",round(JuMP.value(xb[idx]),digits=3),"<=", round(JuMP.value(y[idx]),digits=3), "/", round(JuMP.value(y[idx]*sum(yexsw[gdx]  for gdx in ex_order_groups if idx in Obk["ComplexOrders"][gdx]["members"]    )),digits=3))
        elseif idx in parents
            println(idx, " [", Obk["Orders"][idx]["type"] , "] : ",round(JuMP.value(xb[idx]),digits=3),"<=", round(JuMP.value(y[idx]),digits=3), "/", round(JuMP.value(ypar[idx]),digits=3))
        else
            println(idx, " [", Obk["Orders"][idx]["type"] , "] : ",round(JuMP.value(xb[idx]),digits=3),"<=", round(JuMP.value(y[idx]),digits=3))
        end
    end
end




println()

println("Nodal prices")
for ndx in Obk["Nodes"]
    for tdx in Obk["Periods"]
        println("N$ndx@t$tdx: ",round(JuMP.value(mu[ndx,tdx]),digits=3))
    end
end

if haskey(Obk["ATC"], "Flows")
println()
    println("ATC flows")
    for fdx in keys(sort(Obk["ATC"]["Flows"]))
        for tdx in Obk["Periods"]
            println("$fdx@t$tdx: ", round(JuMP.value(atc_flow[fdx,tdx]),digits=3))
        end
    end

end
 