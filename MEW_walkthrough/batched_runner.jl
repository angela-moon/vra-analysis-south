#using Distributed
#addprocs(10)

#@everywhere begin
include("lct_run_NC.jl")

function long_run(n, j)
    run_dir = "cs_runs_NC/run$(j)"

    # if chain is there, how many chains are there and how many steps has it taken
    if isdir(run_dir)
        existing_files = filter(f -> endswith(f, ".jls"), readdir(run_dir))
        if !isempty(existing_files)
            run_numbers = [parse(Int, match(r"run(\d+)\.jls", f).captures[1]) for f in existing_files]
            last_run    = maximum(run_numbers)
            println("Found existing runs up to run$(last_run) in $(run_dir)")
            last_file      = "$(run_dir)/run$(last_run).jls"
            c_last         = deserialize(last_file)
            initialization = (c_last[3], c_last[4])  # (tree, marked_edges)
            start_i        = last_run + 1
        else
            start_i        = 1
            c1             = main()
            initialization = (c1[3], c1[4])
        end
    else
        println("Creating new directory: $(run_dir)")
        mkpath(run_dir)
        c1             = main()
        initialization = (c1[3], c1[4])
        start_i        = 1
    end

    if start_i <= n
        for i in start_i:n
            c2             = main(; initialization)
            serialize("$(run_dir)/run$(i).jls", c2)
            initialization = (c2[3], c2[4])
            GC.gc() # garbage collector
        end
    else
        println("All $(n) runs already completed for this parameter set.")
    end

    return nothing
end

#= function run_wrapper(params)
    j = params.j
    println("Starting run $j")
    try
        long_run(num_iterations, j)
    catch e
        println("Error in run $j: $e")
        println(stacktrace(catch_backtrace()))
    end
    return nothing
end =#

num_iterations = 100

# j_values          = 1:10
# param_combinations = vec([(j=j,) for j in j_values])
#end

#results = pmap(run_wrapper, param_combinations)

long_run(num_iterations, 1)

using JLD2
cs_array = load("county_splits_SC.jld2", "cs")

cs_array

exit()