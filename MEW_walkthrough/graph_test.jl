using CairoMakie
using DataFrames
using GeoDataFrames
using GeoMakie

using Serialization, Shapefile, DataFrames, Distributions, JSON, ProgressBars
using StatsBase, Graphs, SpecialFunctions
using Distributed, SharedArrays, JLD2

gdf = GeoDataFrames.read("./SC/SC_Processed_Precincts.shp")

function add_partition_column!(
    gdf::AbstractDataFrame,
    partition,
    nodes;
    column::Symbol = :current,
    geography_id::Symbol = :PRECINCTID,
    graph_id::AbstractString = "GEOID",
)
    geography_id in propertynames(gdf) ||
        throw(ArgumentError("geographic data has no $(geography_id) column"))

    #nodes = JSON.parsefile(graph_json)["nodes"]
    assignment = Dict{String, Int}()

    for node in nodes
        # haskey(node, graph_id) ||
            # throw(ArgumentError("graph node has no id"))

        # Graph JSON IDs are zero-based; the sampler's graph vertices are one-based.
        sampler_id = Int(node["id"]) + 1
        #haskey(partition, sampler_id) ||
        #    throw(ArgumentError("partition has no assignment for node $(sampler_id)"))
        assignment[string(node[graph_id])] = Int(partition[sampler_id])
    end

    geographic_ids = string.(gdf[!, geography_id])
    unmatched = unique([id for id in geographic_ids if !haskey(assignment, id)])
    isempty(unmatched) || throw(ArgumentError(
        "$(length(unmatched)) geographic unit(s) have no graph assignment; " *
        "first unmatched ID: $(first(unmatched))",
    ))

    gdf[!, column] = [assignment[id] for id in geographic_ids]
    return gdf
end

c = open("party_runs_SC/run_party4/run100.jls", "r") do io
            deserialize(io)
        end
initial_partition = c[1]
flips             = c[2]
c                 = nothing

current_partition = copy(initial_partition)

data  = JSON.parsefile("SC/SC_dual_graph_stripped.json")
nodes = data["nodes"]
links = data["links"]
g     = Graphs.SimpleGraph(length(nodes))

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

county_ids = df[!, "COUNTYFP"]

ntd_vec = [current_partition[node] for node in 1:nrow(df)]

add_partition_column!(
        gdf,
        ntd_vec,
        nodes;
        column = :current,
        geography_id = :PRECINCTID,
        graph_id = "GEOID",
    )

districts = sort(unique(gdf[!, :current]))
district_index = Dict(districts .=> eachindex(districts))
colors = [district_index[d] for d in gdf[!, :current]]

fig = Figure(size = (1000, 750))
ax = Axis(fig[1, 1]; title = "Georgia Step 3900000", aspect = DataAspect())
hidespines!(ax)
hidedecorations!(ax)

plot = poly!(
    ax,
    gdf.geometry;
    color = colors,
    colormap = :tab20,
    colorrange = (0.5, length(districts) + 0.5),
    strokecolor = (:white, 0.35),
    strokewidth = 0.25,
)
Colorbar(
    fig[1, 2],
    plot;
    label = "District",
    ticks = (eachindex(districts), string.(districts)),
)

display(fig)

for zz in 200:400
    c = open("party_runs_SC/run_party4/run$zz.jls", "r") do io
            deserialize(io)
        end

    ntd_vec = [c[1][node] for node in 1:nrow(df)]

    add_partition_column!(
        gdf,
        ntd_vec,
        nodes;
        column = :current,
        geography_id = :PRECINCTID,
        graph_id = "GEOID",
    )

    districts = sort(unique(gdf[!, :current]))
    district_index = Dict(districts .=> eachindex(districts))
    colors = [district_index[d] for d in gdf[!, :current]]

    fig = Figure(size = (1000, 750),backgroundcolor = :transparent)
    ax = Axis(fig[1, 1]; title = "Georgia - Step $(zz)000", aspect = DataAspect(),backgroundcolor = :transparent)
    hidespines!(ax)
    hidedecorations!(ax)

    plot = poly!(
        ax,
        gdf.geometry;
        color = colors,
        colormap = :tab20,
        colorrange = (0.5, length(districts) + 0.5),
        strokecolor = (:white, 0.35),
        strokewidth = 0.25,
    )

save("./SC_gif/step$zz.png",fig)
end