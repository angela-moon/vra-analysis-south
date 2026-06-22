
library(alarmdata)
library(sf)
library(tidyverse)

map_nc = alarm_50state_map("NC")
map_nc <- map_nc %>%
  select(!adj)

st_write(map_nc, ".NC/NC_Processed/NC_ALARM/nc_alarm.shp")

map_sc = alarm_50state_map("SC")
map_sc <- map_sc %>%
  select(!adj)

st_write(map_sc, "./SC/SC_Processed/SC_ALARM/sc_alarm.shp")

map_ga = alarm_50state_map("GA")
map_ga <- map_ga %>%
  select(!adj)

st_write(map_ga, "./GA/GA_Processed_ALARM/ga_alarm.shp")

map_fl = alarm_50state_map("FL")
map_fl <- map_fl %>%
  select(!adj)

st_write(map_fl, "./FL/FL_Processed_ALARM/fl_alarm.shp")


