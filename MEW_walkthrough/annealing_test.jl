include("lct_run_NC.jl")

a,b,c,d = main(initialization=prepare_warm_start(),beta_county_splits=1,N_ITERS=20_000)
serialize("cs_runs_NC/run_annealing3/run1.jls", [a,b,c,d])

e,f,g,h = main(initialization=[c,d],beta_county_splits=10,N_ITERS=250_000)
serialize("cs_runs_NC/run_annealing3/run2.jls", [e,f,g,h])

i,j,k,l = main(initialization=[g,h],beta_county_splits=1,N_ITERS=20_000)
serialize("cs_runs_NC/run_annealing3/run3.jls", [i,j,k,l])

m,n,o,p = main(initialization=[k,l],beta_county_splits=10,N_ITERS=250_000)
serialize("cs_runs_NC/run_annealing3/run4.jls", [m,n,o,p])