using JSON, DataFrames, Serialization, Graphs, ProgressBars

data  = JSON.parsefile("GA/GA_dual_graph_stripped.json")
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

drewpartitons = BeanoInit.replay_partitions(a,b)

percs =BeanoInit.sorted_percents.(Ref(df), drewpartitons)

plot = plot(title="% Dem Box Plots NC")

for i in 1:14
    boxplot!(plot, ["D$i"], percs[i,:], label="D$i",legend=false,outliers=false)
end

display(plot)

