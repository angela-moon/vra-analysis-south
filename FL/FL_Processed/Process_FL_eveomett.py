import pandas as pd
import geopandas as gpd
import maup
import time
from maup import smart_repair
from gerrychain import Graph

maup.progress.enabled = True

import warnings
warnings.filterwarnings("ignore")

state_ab = "fl"

population1_data = "./FL_Processed/{}_pl2020_b/{}_pl2020_p1_b.shp".format(state_ab, state_ab)
population2_data = "./FL_Processed/{}_pl2020_b/{}_pl2020_p2_b.shp".format(state_ab, state_ab)
vap_data =  "./FL_Processed/{}_pl2020_b/{}_pl2020_p4_b.shp".format(state_ab, state_ab)
vest20_data = "./FL_Processed/{}_vest_20/{}_vest_20.shp".format(state_ab, state_ab)
vest18_data = "./FL_Processed/{}_vest_18/{}_vest_18.shp".format(state_ab, state_ab)
vest16_data = "./FL_Processed/{}_vest_16/{}_vest_16.shp".format(state_ab, state_ab)
cd_data = "./FL_Processed/{}_cong_adopted_2022/P000C0109.shp".format(state_ab)
send_data = "./FL_Processed/{}_sldu_adopted_2022/S027S8058.shp".format(state_ab)
hdist_data = "./FL_Processed/{}_sldl_adopted_2022/H000H8013.shp".format(state_ab)
county_data = "./FL_Processed/{}_pl2020_cnty/{}_pl2020_cnty.shp".format(state_ab, state_ab)

def do_smart_repair(df, min_rook_length = None, snap_precision = 8):
    # change it to the UTM it needs for smart_repair
    df = df.to_crs(df.estimate_utm_crs())
    df = smart_repair(df, min_rook_length = min_rook_length, snap_precision=snap_precision)

    if maup.doctor(df) == False:
        print("maup doctor failed!  Please investigate")
        #raise Exception('maup.doctor failed')
    
    return df

def add_district(dist_df, dist_name, election_df, col_name):
    election_df = election_df.to_crs(election_df.estimate_utm_crs())
    dist_df = dist_df.to_crs(dist_df.estimate_utm_crs())
    # check if it needs to be smart_repair
    if maup.doctor(dist_df) != True:
        dist_df = do_smart_repair(dist_df)

    # assign the pricincts
    precincts_to_district_assignment = maup.assign(election_df.geometry, dist_df.geometry)
    election_df[dist_name] = precincts_to_district_assignment
    for precinct_index in range(len(election_df)):
        election_df.at[precinct_index, dist_name] = dist_df.at[election_df.at[precinct_index, dist_name], col_name]

    return election_df

def rename(original, year):
    party = original[6]
    if party == 'R' or party == 'D':
        return original[3:6] + year + original[6]
    else:
        return original[3:6] + year + 'O'
    
pop_col = ['TOTPOP', 'HISP', 'NH_WHITE', 'NH_BLACK', 'NH_OTHER', 'VAP', 'HVAP', 'WVAP', 'BVAP', 'OTHERVAP']

def check_population(population, df):
    pop_check = pd.DataFrame({
        'pop_col': pop_col,
        'population_df': population[pop_col].sum(), 
        'vest_base': df[pop_col].sum(),
        'equal': [x == y for x, y in zip(population[pop_col].sum(), df[pop_col].sum())]
    })
    if pop_check['equal'].mean() < 1:
        print(pop_check)
        raise Exception("population doesn't agree")

    else:
        print("population agrees")

def add_vest(vest, df, year, population, start_col, snap_precision = 8):
    df = df.to_crs(df.estimate_utm_crs())
    vest = vest.to_crs(vest.estimate_utm_crs())
    population = population.to_crs(population.estimate_utm_crs())
    df_crs = df.crs
    vest_crs = vest.crs
    
     # check if it needs to be smart_repair
    if maup.doctor(vest) != True:
        vest = do_smart_repair(vest, snap_precision = snap_precision)
    
    # rename the columns
    original_col = vest.columns[start_col:-1]
    new_col = [rename(i, year) for i in original_col]
    rename_dict = dict(zip(original_col, new_col))
    vest = vest.rename(columns=rename_dict)
    vest = vest.groupby(level=0, axis=1).sum() # combine all the other party's vote into columns with sufix "O"
    col_name = list(set(new_col))
    col_name.sort()
    
    # make the blocks from precincts by weight
    vest = gpd.GeoDataFrame(vest, crs=vest_crs)
    election_in_block = population[["VAP", 'geometry']] # population_df is in block scale
    blocks_to_precincts_assignment = maup.assign(election_in_block.geometry, vest.geometry)
    weights = election_in_block["VAP"] / blocks_to_precincts_assignment.map(election_in_block["VAP"].groupby(blocks_to_precincts_assignment).sum())
    weights = weights.fillna(0)
    prorated = maup.prorate(blocks_to_precincts_assignment, vest[col_name], weights)
    election_in_block[col_name] = prorated
    
    # assign blocks to precincts
    election_in_block = gpd.GeoDataFrame(election_in_block, crs=vest_crs)
    df = gpd.GeoDataFrame(df, crs=df_crs)
    block_to_pricinct_assginment = maup.assign(election_in_block.geometry, df.geometry)
    df[col_name] = election_in_block[col_name].groupby(block_to_pricinct_assginment).sum()
    df = df.groupby(level=0, axis=1).sum()
    df = gpd.GeoDataFrame(df, crs = df_crs)
    # check if population agrees
    check_population(population, df)
    
    return df

def add_vest_base(vest, start_col, year, county = None, min_rook_length = None, snap_precision = 8):
    vest = vest.to_crs(vest.estimate_utm_crs())
    vest_crs = vest.crs
    original_col = vest.columns[start_col:-1]
    new_col = [rename(i, year) for i in original_col]
    rename_dict = dict(zip(original_col, new_col))
    vest = vest.rename(columns=rename_dict)
    vest = vest.groupby(level=0, axis=1).sum()
    vest = gpd.GeoDataFrame(vest, crs=vest_crs)

    if county is not None:
        county = county.to_crs(county.estimate_utm_crs())
        vest = smart_repair(vest, nest_within_regions = county, min_rook_length = min_rook_length, snap_precision = snap_precision) # nest precincts within counties

    else:
        vest = smart_repair(vest, min_rook_length = min_rook_length, snap_precision = snap_precision) 
    
    return vest

def check_small_boundary_lengths(vest_base):
    import copy
    vest_base = vest_base.to_crs(vest_base.estimate_utm_crs())

    boundaries = copy.deepcopy(vest_base)
    boundaries["geometry"] = boundaries.geometry.boundary  # get boundaries
    neighbors = gpd.sjoin(boundaries, vest_base, predicate="intersects") # find boundaries that intersect
    neighbors = neighbors[neighbors.index != neighbors.index_right] # remove boundaries of a region with itself

    # compute shared border length using intersection
    borders = list(neighbors.apply(
        lambda row: row.geometry.intersection(vest_base.loc[row.index_right, "geometry"]).length, axis=1
    ))

    borders.sort()
    
    return borders

population1_df = gpd.read_file(population1_data)
population2_df = gpd.read_file(population2_data)
vap_df = gpd.read_file(vap_data)
county_df = gpd.read_file(county_data)

population2_df = population2_df.drop(columns=['SUMLEV', 'LOGRECNO', 'GEOID', 'COUNTY', 'geometry'])
vap_df = vap_df.drop(columns=['SUMLEV', 'LOGRECNO', 'GEOID', 'COUNTY', 'geometry'])

population_df = pd.merge(population1_df, population2_df, on='GEOID20')
population_df = pd.merge(population_df, vap_df, on='GEOID20')
population_df = population_df.to_crs(population_df.estimate_utm_crs())

maup.doctor(population_df)

population_df['NH_BLACK'] = population_df.apply(lambda block_pop: block_pop['P0020006'] + block_pop['P0020013'] + block_pop['P0020018'] + block_pop['P0020019'] + block_pop['P0020020'] + block_pop['P0020021'] + block_pop['P0020029'] + block_pop['P0020030'] + block_pop['P0020031'] + block_pop['P0020032'] + block_pop['P0020039'] + block_pop['P0020040'] + block_pop['P0020041'] + block_pop['P0020042'] + block_pop['P0020043'] + block_pop['P0020044'] + block_pop['P0020050'] + block_pop['P0020051'] + block_pop['P0020052'] + block_pop['P0020053'] + block_pop['P0020054'] + block_pop['P0020055'] + block_pop['P0020060'] + block_pop['P0020061'] + block_pop['P0020062'] + block_pop['P0020063'] + block_pop['P0020066'] + block_pop['P0020067'] + block_pop['P0020068'] + block_pop['P0020069'] + block_pop['P0020071'] + block_pop['P0020073'],1)
population_df['BVAP'] = population_df.apply(lambda block_pop_vap: block_pop_vap['P0040006'] + block_pop_vap['P0040013'] + block_pop_vap['P0040018'] + block_pop_vap['P0040019'] + block_pop_vap['P0040020'] + block_pop_vap['P0040021'] + block_pop_vap['P0040029'] + block_pop_vap['P0040030'] + block_pop_vap['P0040031'] + block_pop_vap['P0040032'] + block_pop_vap['P0040039'] + block_pop_vap['P0040040'] + block_pop_vap['P0040041'] + block_pop_vap['P0040042'] + block_pop_vap['P0040043'] + block_pop_vap['P0040044'] + block_pop_vap['P0040050'] + block_pop_vap['P0040051'] + block_pop_vap['P0040052'] + block_pop_vap['P0040053'] + block_pop_vap['P0040054'] + block_pop_vap['P0040055'] + block_pop_vap['P0040060'] + block_pop_vap['P0040061'] + block_pop_vap['P0040062'] + block_pop_vap['P0040063'] + block_pop_vap['P0040066'] + block_pop_vap['P0040067'] + block_pop_vap['P0040068'] + block_pop_vap['P0040069'] + block_pop_vap['P0040071'] + block_pop_vap['P0040073'],1)

population_df['NH_OTHER'] = population_df.apply(lambda block_pop: block_pop['P0020001'] - block_pop['P0020002'] - block_pop['P0020005'] - block_pop['NH_BLACK'],1)
population_df['OTHERVAP'] = population_df.apply(lambda block_pop_vap: block_pop_vap['P0040001'] - block_pop_vap['P0040002'] - block_pop_vap['P0040005'] - block_pop_vap['BVAP'],1)

rename_dict = {'P0020001': 'TOTPOP', 'P0020002': 'HISP', 'P0020005': 'NH_WHITE', 
               'P0040001': 'VAP', 'P0040002': 'HVAP', 'P0040005': 'WVAP'}

population_df.rename(columns=rename_dict, inplace = True)

maup.doctor(county_df)

vest20 = gpd.read_file(vest20_data)

start_col = 3
vest_base_data = vest20
year = '20'

vest_base = add_vest_base(vest_base_data, start_col, year, county = county_df)

borders = check_small_boundary_lengths(vest_base)
print(borders[3000:5000])

vest_base = do_smart_repair(vest_base, min_rook_length = 30.5, snap_precision=10)

# vap and population have the same GEOID20
blocks_to_precincts_assignment = maup.assign(population_df.geometry, vest_base.geometry)

vest_base[pop_col] = population_df[pop_col].groupby(blocks_to_precincts_assignment).sum()

election_df = gpd.GeoDataFrame(vest_base)

check_population(population_df, vest_base)

vest18 = gpd.read_file(vest18_data)
vest16 = gpd.read_file(vest16_data)

election_df = smart_repair(election_df, min_rook_length = 30.5, snap_precision=8)

election_df = smart_repair(election_df, min_rook_length = 30.5, snap_precision=8)

maup.doctor(election_df)

# check the result here
election_df = add_vest(vest18, election_df, '18', population_df, start_col)

election_df = add_vest(vest16, election_df, '16', population_df, start_col)

election_df = smart_repair(election_df, snap_precision=8)

cong_df = gpd.read_file(cd_data)
cong_df = cong_df.to_crs(cong_df.estimate_utm_crs())
send = gpd.read_file(send_data)
send = send.to_crs(send.estimate_utm_crs())
hdist = gpd.read_file(hdist_data)
hdist = hdist.to_crs(hdist.estimate_utm_crs())

election_df = add_district(cong_df, "CD", election_df, "DISTRICT")

election_df = add_district(send, "SEND", election_df, "DISTRICT")
election_df = add_district(hdist, "HDIST", election_df, "DISTRICT")

maup.doctor(election_df)

base_columns = {}
if 'COUNTY' + year not in election_df.columns:
    base_columns = {
        'COUNTY':'COUNTY'+year,
        'PRECINCT':'PRECINCT'+year, 
        'PCT_STD':'PCT_STD'+year
    }
election_df.rename(columns=base_columns, inplace = True)

# reorder the columns
fixed_columns = [
    'COUNTY'+year,
    'PRECINCT'+year, 
    'PCT_STD'+year,
    'SEND',
    'HDIST',
    'TOTPOP',
    'NH_BLACK',
    'NH_OTHER',
    'NH_WHITE',
    'HISP',
    'VAP',
    'HVAP',
    'WVAP',
    'BVAP',
    'OTHERVAP']

election_columns = [col for col in election_df.columns if col not in fixed_columns]
final_col = fixed_columns + election_columns
election_df = election_df[final_col]

election_df.to_file("./output/FL_Processed_Precincts_eveomett.shp")
election_df.to_file("./output/FL_Processed_Precincts_eveomett.json", driver='GeoJSON')

# Only do once to build json and read from file when generating ensembles
graph = Graph.from_file("./output/FL_Processed_Precincts_eveomett.shp", ignore_errors=True)
graph.to_json("./output/FL_Processed_Precincts_eveomett.json")

