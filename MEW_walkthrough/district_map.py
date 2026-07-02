#!/Users/atticusmcwhorter/anaconda3/envs/skool/bin/python3
"""
district_map.py — Colorado congressional district choropleth.
Run after voteshare_viz.jl has exported partition_max_dem.csv and
partition_best_metric.csv.

Usage (from the colorado/ folder):
    /Users/atticusmcwhorter/anaconda3/envs/skool/bin/python3 district_map.py

Shapefile: Colorado/co_vest_20/CO_Processed_Precincts.shp
Node-to-row alignment is resolved automatically via vote-tally matching.
"""
import json, sys
import numpy as np
import pandas as pd
import geopandas as gpd
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import matplotlib.cm as cm

STATE  = "Colorado"
SHP    = "Colorado/co_vest_20/CO_Processed_Precincts.shp"
GRAPH  = "Colorado/co.json"
K      = 8
D_COL  = "PRE20D"
R_COL  = "PRE20R"


def district_voteshares(nodes, district_arr):
    """Returns D two-party voteshare per district."""
    d = np.zeros(K)
    r = np.zeros(K)
    for i, node in enumerate(nodes):
        dist = int(district_arr[i]) - 1
        if 0 <= dist < K:
            d[dist] += float(node.get(D_COL) or 0)
            r[dist] += float(node.get(R_COL) or 0)
    return np.where(d + r > 0, d / (d + r), 0.5)


def build_node_to_shp(gdf, nodes):
    """Map JSON node index → shapefile row index via vote-tally matching.

    The shapefile row order does not match the JSON node order, so positional
    assignment would scramble the district colors.  Matching on rounded
    (Biden, Trump) 2020 totals (G20PREDBID ↔ PRE20D, G20PRERTRU ↔ PRE20R)
    identifies the correct row for every unambiguous precinct.
    """
    shp_d = gdf["G20PREDBID"].round().astype(int).values
    shp_r = gdf["G20PRERTRU"].round().astype(int).values

    lookup: dict = {}
    for si in range(len(gdf)):
        k = (shp_d[si], shp_r[si])
        lookup[k] = None if k in lookup else si  # None = duplicate key

    node_to_shp = np.full(len(nodes), -1, dtype=int)
    for ji, node in enumerate(nodes):
        key = (round(float(node.get("PRE20D") or 0)),
               round(float(node.get("PRE20R") or 0)))
        val = lookup.get(key, -1)
        if val is not None and val >= 0:
            node_to_shp[ji] = val

    n_unmatched = int((node_to_shp == -1).sum())
    if n_unmatched:
        print(f"Warning: {n_unmatched} nodes had ambiguous vote-tally keys; "
              "those precincts default to district 1 in the map.")
    return node_to_shp


def draw_panel(ax, gdf, district_arr, vs, title):
    gdf = gdf.copy()
    gdf["district"] = district_arr
    gdf["vs"] = np.array(vs)[district_arr - 1]

    # RdBu: blue end = high D share, red end = high R share
    norm = mcolors.TwoSlopeNorm(vcenter=0.5, vmin=0.2, vmax=0.8)
    gdf.plot(column="vs", ax=ax, cmap="RdBu", norm=norm,
             linewidth=0, edgecolor="none")

    districts = gdf.dissolve(by="district")
    districts.boundary.plot(ax=ax, color="black", linewidth=0.5, zorder=3)

    for dist_id, row in districts.iterrows():
        pt = row.geometry.representative_point()
        share = vs[int(dist_id) - 1]
        dark = share > 0.65 or share < 0.35
        ax.annotate(
            f"{share:.0%} D", xy=(pt.x, pt.y), ha="center", va="center",
            fontsize=5, color="white" if dark else "black",
            fontweight="bold", zorder=4,
        )

    ax.set_title(title, fontsize=12, pad=8)
    ax.axis("off")


def main():
    for f in ("partition_max_dem.csv", "partition_best_metric.csv"):
        if not __import__("pathlib").Path(f).exists():
            print(f"Missing {f} — run voteshare_viz.jl first to export partitions.")
            sys.exit(1)

    if not __import__("pathlib").Path(SHP).exists():
        print(f"Shapefile not found at {SHP}.")
        print("Place the CO precinct shapefile at Colorado/co_vest_20/CO_Processed_Precincts.shp and re-run.")
        sys.exit(1)

    gdf = gpd.read_file(SHP)
    with open(GRAPH) as f:
        nodes = json.load(f)["nodes"]

    node_to_shp = build_node_to_shp(gdf, nodes)

    panels = [
        ("partition_max_dem.csv",     "Max Democratic Seats"),
        ("partition_best_metric.csv", "Best Metric (Pack + Crack)"),
    ]

    fig, axes = plt.subplots(1, 2, figsize=(18, 9), constrained_layout=True)

    for ax, (csv_file, title) in zip(axes, panels):
        part         = pd.read_csv(csv_file)
        district_arr = part["district"].values.astype(int)  # indexed by JSON node
        vs           = district_voteshares(nodes, district_arr)

        # Reorder into shapefile row order before drawing
        shp_district = np.ones(len(gdf), dtype=int)  # fallback: district 1
        for ji, si in enumerate(node_to_shp):
            if si >= 0:
                shp_district[si] = district_arr[ji]

        draw_panel(ax, gdf, shp_district, vs, title)

    norm = mcolors.TwoSlopeNorm(vcenter=0.5, vmin=0.2, vmax=0.8)
    sm   = cm.ScalarMappable(cmap="RdBu", norm=norm)
    sm.set_array([])
    cbar = fig.colorbar(sm, ax=axes.tolist(), orientation="vertical",
                        fraction=0.015, pad=0.02, shrink=0.65)
    cbar.set_label("Democratic two-party vote share", fontsize=10)
    cbar.set_ticks([0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
    cbar.set_ticklabels(["20%", "30%", "40%", "50%", "60%", "70%", "80%"])

    fig.suptitle(f"{STATE} Congressional Districts — Optimization Results",
                 fontsize=14)
    fig.savefig("district_maps.png", dpi=150, bbox_inches="tight")
    print("Saved → district_maps.png")
    plt.show()


if __name__ == "__main__":
    main()
