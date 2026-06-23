library(alarmdata)
library(redist)
library(tidyverse)
library(sf)
library(data.table)

state= "GA"
nsims_per_run= 2500
runs= 2
ncores=1
seed= 1861
pop_tol = 0.01
compactness= 1
pop_temper= 0.05
use_county_constraint= TRUE
out_dir= "outputs_sc_vra_off"

map <- alarm_50state_map("GA")

set.seed(seed)

county_arg <- if (isTRUE(use_county_constraint)) map$county else NULL
constraints_vra_off <- redist::redist_constr(map)  # could vary based on the alarm setup? Some states only had VRA though

plans_vra_off <- redist::redist_smc(
  map = map,
  nsims = nsims_per_run,
  runs = runs,
  ncores = ncores,
  compactness = compactness,
  pop_temper = pop_temper,
  counties = county_arg,
  constraints = constraints_vra_off,
  ref_name = "cd_2020",
  verbose = TRUE
) |>
  redist::match_numbers("cd_2020")

plans_sampled <- redist::subset_sampled(plans_vra_off)

summary(plans_sampled)

plan_mat <- redist::get_plans_matrix(plans_sampled)

rownames(plan_mat) <- map$GEOID

fwrite(as.data.frame(plan_mat), "ga_alarm_plans.csv", row.names = TRUE)
