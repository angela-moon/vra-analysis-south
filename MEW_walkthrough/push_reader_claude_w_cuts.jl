using Serialization, Shapefile, DataFrames, Distributions, JSON, ProgressBars
using StatsBase, Graphs, SpecialFunctions
using Distributed, SharedArrays, JLD2

addprocs(min(8, Sys.CPU_THREADS - 1))

@everywhere begin
    using Serialization, Graphs, StatsBase, DataFrames, Shapefile, JSON, ProgressBars, Distributions, SpecialFunctions
    include("Marked_edges/beano2.2_WI.jl")
end

@everywhere g_ref          = Ref{Any}(nothing)
@everywhere df_ref         = Ref{Any}(nothing)
@everywhere county_ids_ref = Ref{Any}(nothing)

data  = JSON.parsefile("NC/NC_dual_graph_stripped.json")
nodes = data["nodes"]
links = data["links"]
g     = Graphs.SimpleGraph(length(nodes))
for link in links
    u, v = link["source"], link["target"]
    add_edge!(g, simple_edge(u + 1, v + 1))
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

county_ids = df[!, "COUNTYFP"]

for pid in workers()
    remotecall_fetch(pid, g, df, county_ids) do g_local, df_local, county_ids_local
        g_ref[]          = g_local
        df_ref[]         = df_local
        county_ids_ref[] = county_ids_local
    end
end

@everywhere function sorted_percents_sc(df, ptition)
    tot = tally(df, "G24PREDHAR", ptition) + tally(df, "G24PRERTRU", ptition)
    dem = tally(df, "G24PREDHAR", ptition)

    percs = dem ./ tot

    return sort!(percs)
end

@everywhere function county_splits(ntd, county_ids)
    splits = 0
    for cty in Set(county_ids)
        cty_nodes = findall(county_ids .== cty)
        cty_districts = Set(ntd[cty_nodes])
        if length(cty_districts) > 1
            splits += 1
        end
    end
    return splits
end

@everywhere function process_single_run(run_dir, i)
    g          = g_ref[]
    df         = df_ref[]
    county_ids = county_ids_ref[]
    n          = nrow(df)
    rows       = Vector{Vector{Float16}}()
    splits     = Vector{Int16}()
    cuts       = Vector{Int32}()

    try
        c = open("$(run_dir)/run$(i).jls", "r") do io
            deserialize(io)
        end
        initial_partition = c[1]
        flips             = c[2]
        c                 = nothing

        current_partition = copy(initial_partition)
        ntd_vec = [current_partition[node] for node in 1:n]

        push!(rows, Vector{Float16}(sorted_percents_sc(df, current_partition)))
        push!(splits, county_splits(ntd_vec, county_ids))
        push!(cuts, Int32(length(cut_edges(current_partition, g))))

        for flip in flips
            if haskey(flip, 0)
                push!(rows, Vector{Float16}(sorted_percents_sc(df, current_partition)))
                push!(splits, county_splits(ntd_vec, county_ids))
                push!(cuts, Int32(length(cut_edges(current_partition, g))))
                continue
            end
            for (node, new_part) in flip
                current_partition[node] = new_part
                ntd_vec[node]           = new_part
            end
            push!(rows, Vector{Float16}(sorted_percents_sc(df, current_partition)))
            push!(splits, county_splits(ntd_vec, county_ids))
            push!(cuts, Int32(length(cut_edges(current_partition, g))))
        end

        flips = nothing
        GC.gc(false)

    catch e
        println("Error processing $(run_dir)/run$(i).jls: $e")
        println(stacktrace(catch_backtrace()))
        return nothing
    end

    # return as (niters × ndistricts) matrix — no jagged arrays — plus the
    # per-iteration county-split and cut-edge counts
    return reduce(hcat, rows)', splits, cuts
end

# Process one run_dir, write result to a temp file, return filename
function process_one_dir(run_dir, num_runs, chain_idx, tmp_prefix="tmp_perc")
    println("Processing $run_dir ...")
    tasks = collect(1:num_runs)

    results = pmap(tasks; on_error=ex->nothing) do i
        process_single_run(run_dir, i)
    end

    valid = [r for r in results if r !== nothing]
    if isempty(valid)
        println("  WARNING: all runs failed for $run_dir")
        return nothing
    end
    println("  $(length(valid)) / $num_runs runs succeeded")

    perc_mats  = [r[1] for r in valid]
    split_vecs = [r[2] for r in valid]
    cut_vecs   = [r[3] for r in valid]

    # stack all runs along iterations axis: each mat is (niters × ndistricts)
    # cat along dim 1 gives (niters*num_runs × ndistricts)
    combined = reduce(vcat, perc_mats)       # (total_iters × ndistricts)
    arr = Array{Float16, 2}(undef, size(combined, 2), size(combined, 1))
    arr .= combined'                         # (ndistricts × total_iters)

    splits_arr = reduce(vcat, split_vecs)    # (total_iters,)
    cuts_arr   = reduce(vcat, cut_vecs)      # (total_iters,)

    tmp_file = "$(tmp_prefix)_chain$(chain_idx).jld2"
    jldsave(tmp_file; arr, splits_arr, cuts_arr)
    println("  Written $tmp_file  ($(round(sizeof(arr)/1024^3, digits=3)) GB)")

    results    = nothing
    valid      = nothing
    perc_mats  = nothing
    split_vecs = nothing
    cut_vecs   = nothing
    combined   = nothing
    arr        = nothing
    splits_arr = nothing
    cuts_arr   = nothing
    GC.gc(true)

    return tmp_file
end

# Concatenate temp files into final output
function compile_tmp_files(tmp_files, out_file, splits_out_file, cuts_out_file)
    println("Compiling $(length(tmp_files)) temp files into $out_file ...")

    # Read first to get dims
    ndistricts, niters = jldopen(tmp_files[1], "r") do jf
        size(jf["arr"])
    end
    nchains = length(tmp_files)

    println("Final array: ndistricts=$ndistricts, niters=$niters, nchains=$nchains")
    println("Estimated size: $(round(ndistricts * niters * nchains * 2 / 1024^3, digits=2)) GB (Float16)")

    final_arr        = Array{Float16, 3}(undef, ndistricts, niters, nchains)
    final_splits_arr = Array{Int16, 2}(undef, niters, nchains)
    final_cuts_arr   = Array{Int32, 2}(undef, niters, nchains)

    for (ci, tmp_file) in enumerate(tmp_files)
        jldopen(tmp_file, "r") do jf
            final_arr[:, :, ci]     .= jf["arr"]
            final_splits_arr[:, ci] .= jf["splits_arr"]
            final_cuts_arr[:, ci]   .= jf["cuts_arr"]
        end
        println("  Loaded chain $ci / $nchains")
    end

    jldsave(out_file; perc_arr=final_arr, compress=true)
    println("Saved $out_file")

    jldsave(splits_out_file; county_splits_arr=final_splits_arr, compress=true)
    println("Saved $splits_out_file")

    jldsave(cuts_out_file; cut_edges_arr=final_cuts_arr, compress=true)
    println("Saved $cuts_out_file")

    # Clean up temp files
    for tmp_file in tmp_files
        rm(tmp_file)
    end
    println("Temp files deleted.")
end

# --- Main ---

run_dirs = ["cs_runs_NC/run3/"]
num_runs = 10
tmp_files = String[]
for (ci, run_dir) in enumerate(run_dirs)
    tmp = process_one_dir(run_dir, num_runs, ci)
    tmp !== nothing && push!(tmp_files, tmp)
end
compile_tmp_files(tmp_files, "percents_NC4.jld2", "county_splits_NC4.jld2", "edges_NC4.jld2")
exit()

#### PROCESSING DATA
using StatsPlots, Plots

cs_array = load("county_splits_NC4.jld2", "county_splits_arr")
percents_array = load("./percents_NC4.jld2", "perc_arr")
cut_edges_array = load("edges_NC4.jld2", "cut_edges_arr")

key_percs = hcat(percents_array[:,160_000:175_000,1],percents_array[:,320_000:end,1])

box_list = []

b = plot(title="% Dem Box Plots NC")

for i in 1:14
    boxplot!(b, ["D$i"], percents_array[i,:], label="D$i",legend=false,outliers=false)
end
display(b)


scatter(key_percs)

plot(cut_edges_array, title="Min CS Cut Edges NC")

plot(cs_array, title="Min County Splits NC")

p = plot(title="Dem % by district NC")
for i in 1:14
    plot!(percents_arrays[i,:,1])
end
display(p)



for i in 1:14
    plot!(parr5[i,:,1])
end
display(p)

box_list = []

b = plot(title="% Dem Box Plots NC")



percents_array = load("./percents_NC_annealing2.jld2", "perc_arr")

for i in 1:14
    boxplot!(b, ["D$i"], percents_array[i,:,1], label="D$i",legend=false,outliers=false)
end
display(b)

parr5 = load("./cs_runs_NC_jld2/percents_NC_min_cs_seed5.jld2", "perc_arr")
parr4 = load("./cs_runs_NC_jld2/percents_NC_min_cs_seed4.jld2", "perc_arr")
parr3 = load("./cs_runs_NC_jld2/percents_NC_min_cs_seed3.jld2", "perc_arr")
parr2 = load("./cs_runs_NC_jld2/percents_NC_min_cs_seed2.jld2", "perc_arr")
parr1 = load("./cs_runs_NC_jld2/percents_NC_min_cs3.jld2", "perc_arr")
percents_arrays = [parr1, parr2, parr3, parr4, parr5]

for j in 1:14
    for i in 1:5
        boxplot!(b, ["$(i)D$j"], percents_arrays[i][j,:,1], label="$(i)D$j",legend=false,outliers=false)
    end
end

display(b)

cut_edges_array = load("edges_NC_annealing2.jld2", "cut_edges_arr")
plot(cut_edges_array, title="Min CS Cut Edges NC")

p1 = plot(title="% Dem Box Plots NC Seed 1")
p2 = plot(title="% Dem Box Plots NC Seed 2")
p3 = plot(title="% Dem Box Plots NC Seed 3")
p4 = plot(title="% Dem Box Plots NC Seed 4")
p5 = plot(title="% Dem Box Plots NC Seed 5")

party_plots = [p1,p2,p3,p4,p5]
seed_dems = [[0.30645412186465704, 0.3146334491733237, 0.40184765312171733, 0.41329216032266197, 0.4221326160476314, 0.43192365113491227, 0.45303881769983095, 0.45587338556973284, 0.4999845210454248, 0.5389868922289281, 0.5472802362406916, 0.6440875447196572, 0.6612906771401983, 0.676746289173188],[0.285417038226027, 0.37993587831792425, 0.3877009585369047, 0.40649145751083915, 0.42223343042216477, 0.4416144281163293, 0.45565741485251393, 0.4695400107234301, 0.5229848767912496, 0.5322070640810135, 0.5570282550919179, 0.5945157886732192, 0.6342189810801163, 0.6808314287568222], [0.33079812975971434, 0.33480380719049563, 0.38477585973392786, 0.390707055799481, 0.42176568285648414, 0.4333629044147124, 0.4438398159497212, 0.45565741485251393, 0.47987383488762964, 0.5213799768755708, 0.5296256516119858, 0.6413780404104659, 0.6991490107756004, 0.7093496474952722], [0.29023485299923735, 0.4021573035837394, 0.41703009185618634, 0.421016962187156, 0.4505359145478278, 0.4546656419659427, 0.4686505242043494, 0.49051442307692306, 0.5043992241623841, 0.5250299363948805, 0.5352914248656484, 0.566658581184461, 0.628757858500795, 0.6344890116761599], [0.29023485299923735, 0.4021573035837394, 0.41703009185618634, 0.421016962187156, 0.4505359145478278, 0.4546656419659427, 0.4686505242043494, 0.49051442307692306, 0.5043992241623841, 0.5250299363948805, 0.5352914248656484, 0.566658581184461, 0.628757858500795, 0.6344890116761599]]
dist_labs = ["D$i" for i in 1:14]

for i in 1:5
    for j in 1:14
         boxplot!(party_plots[i], ["D$j"], percents_arrays[i][j,:,1], label="D$j",legend=false,outliers=false)
    end
    scatter!(dist_labs, seed_dems[i], color=:red, markersize=6, marker=:star)
    savefig(party_plots[i],"./cs_runs_NC_plots/seed$(i)_party.png")
end

differences = [[] for i in 1:5]

for i in 1:5
    for j in 1:14
         diff = seed_dems[i][j] - median(percents_arrays[i][j,:,1])
         push!(differences[i],round(diff,digits=5))
    end
    println(round(mean(differences[i]), digits=7))
end

differences

squared = [[] for i in 1:5] 

for i in 1:5
    for j in 1:14
        push!(squared[i],differences[i][j]^2)
    end
    println(round(mean(squared[i]), digits=7))
end