using JSON

include("lct_mew.jl")
include("lct_run_NC.jl")

data  = JSON.parsefile("NC/NC_dual_graph_stripped.json")
nodes = data["nodes"]
links = data["links"]

is_boundary = [node["boundary_node"] for node in nodes]
boundary_lengths = zeros(length(nodes))
for i in 1:length(nodes)
    if is_boundary[i]
        boundary_lengths[i] = nodes[i]["boundary_perim"]
    end
end
areas = [node["area"] for node in nodes]

perim_dict = Dict()
g = Graphs.SimpleGraph(length(nodes))
for link in links
    u, v = link["source"], link["target"]
    add_edge!(g, simple_edge(u + 1, v + 1))
    perim_dict[simple_edge(u + 1, v + 1)] = link["shared_perim"]
end

df_dict = Dict()
for node in nodes
    for (key, value) in node
        key == "id" && continue
        if !haskey(df_dict, key)
            df_dict[key] = []
        end
        push!(df_dict[key], value)
    end
end
max_len = maximum(length(v) for v in values(df_dict))
for (key, vals) in df_dict
    while length(vals) < max_len
        push!(vals, missing)
    end
end
df = DataFrame(df_dict)
insertcols!(df, 1, :id => 1:nrow(df))

county_ids = df[!,"COUNTYFP"]
Set(county_ids)

### business ####

seed = JSON.parsefile("NC_Seed_Plans/nc_seed_plan1.json") # read seed1
GEOIDs = [node["GEOID"] for node in nodes] # tell us what order the geoids are

seed_1_ntd = [seed[GEOIDs[i]] + 1 for i in 1:length(nodes)] # find geoid from geoids for that node and find the part id from the json and add 1

module BeanoInit
    using ProgressBars
    include("./Marked_edges/beano2.2_WI.jl")
end

districts = [[i for i in 1:length(seed_1_ntd) if seed_1_ntd[i]==d] for d in unique(seed_1_ntd)]
t, m = BeanoInit.partition_to_tree_marked_edges(g, districts)

main(; initialization = [t, m])
