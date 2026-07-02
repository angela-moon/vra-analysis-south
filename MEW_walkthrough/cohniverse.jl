
println(names(df))

county_ids = df[!,"COUNTYFP"]

Set(county_ids)

# sets are a list without anything repeatign
county_ids[17]

function county_splits(g, ntd, county_ids)
    splits = 0
    for cty in Set(county_ids)
        cty_nodes = findall(county_ids .== cty) # nodes/districts in the county
        cty_districts = Set(ntd[cty_nodes]) # unique list of different districts in a county
        if length(cty_districts) > 1
            splits +=1
        end
    end
    return splits
end

ntd_enacted = df[!,"CON"]
ntd_ss = df[!,"SLDU"]

county_splits(g, ntd_enacted, county_ids)

function make_county_splits_energy(
    beta            :: Float64,
    county_ids      :: Vector{Any},


)
    return function(g, new_ntd, old_ntd) 
        # g=  graph, ntd = node to district, K= # districts
        cty_splits_new = county_splits(g, new_ntd, county_ids)
        cty_splits_old = county_splits(g, old_ntd, county_ids)

        return -beta * (cty_splits_new - cty_splits_old)
    end
end

el_tigre = make_county_splits_energy(0.4, county_ids)

el_tigre(g,ntd_enacted, ntd_ss) # returns acceptnce ratio

a, b, c, d = main()


partitions = BeanoInit.replay_partitions(a,b)
final_part = BeanoInit.partition(c,d)
@assert partitions[end] == final_part

ntds = [[partition[i] for i in 1:length(partition)] for partition in partitions]
cty_splits = county_splits.(Ref(g),ntds, Ref(county_ids))

using Plots
plot(cty_splits)

unique(ntds)

function make_combined_energy(
    beta_county_splits  :: Number,
    county_ids          :: Vector{Any},
    beta_cuts           :: Number,
    cty_target          :: Number,
    target_cuts         :: Number
)
    return function combined_energy(g, new_ntd, old_ntd)
        cty_splits_new = county_splits(g, new_ntd, county_ids)
        cty_splits_old = county_splits(g, old_ntd, county_ids)

        cuts_new = count(e -> new_ntd[src(e)] != new_ntd[dst(e)],edges(g))
        cuts_old = count(e -> old_ntd[src(e)] != old_ntd[dst(e)],edges(g))

        return -beta_county_splits * ((cty_splits_new - cty_target)^2 - (cty_splits_old - cty_target)^2) - beta_cuts * ((cuts_new - target_cuts)^2 - (cuts_old - target_cuts)^2)
    end
end

a,b,c,d = main()


drewpartitions = BeanoInit.replay_partitions(a,b)
final_part = BeanoInit.partition(c,d)
@assert partitions[end] == final_part

ntds = [[partition[i] for i in 1:length(partition)] for partition in partitions]
cty_splits = county_splits.(Ref(g),ntds, Ref(county_ids))

plot(cty_splits)

cs = length.(BeanoInit.cut_edges.(partitions, Ref(g)))

plot(cs)


ntd_con = df[!,"CON"]

districts = [[i for i in 1:length(ntd_con) if ntd_con[i] == d] for d in unique(ntd_con)]

for district in districts
    g_sub = induced_subgraph(g, district)[1]
    if !is_connected(g_sub)
        println("not connected")
        println(length(connected_components(g_sub)))
    end
end

t, m = BeanoInit.partition_to_tree_marked_edges(g, districts)

main(; initialization = [t, m])