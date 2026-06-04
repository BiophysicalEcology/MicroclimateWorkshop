# =============================================================================
# Julia Microclimate Modelling Workshop
# Montpellier, France — June 2026
#
# Run interactively in VS Code:
#   • Ctrl+Enter  — run current cell (between # %% markers)
#   • Shift+Enter — run cell and move to next
#   • Open the Julia REPL first: Alt+J Alt+O"
#
# Make sure RASTERDATASOURCES_PATH is set before starting:
#   ENV["RASTERDATASOURCES_PATH"] = joinpath(homedir(), "spatial_data")
# =============================================================================

# %%
# Activate the workshop environment (packages installed by setup.jl)
include("setup.jl")

# =============================================================================
# PART 1 — Physical units with Unitful.jl
# =============================================================================
#
# One of the most common sources of bugs in scientific code is unit confusion:
# metres vs feet, Kelvin vs Celsius, Pa vs hPa. R and Fortran have no built-in
# concept of units — you carry them in your head or in variable names. Another 
# equally serious bug in code or model formulation is dimensional errors, which
# renders physical models meaningless.
#
# Unitful.jl attaches units to numbers as part of their *type*, not as runtime
# metadata. This means:
#   • Unit conversions are computed at compile time — zero runtime overhead.
#   • Dimension mismatches are caught before the code runs.
#   • The generated machine code is identical to plain Float64 arithmetic.

# %%
using Unitful

# Example 1: same units — works as expected
a = 1.5u"m"
b = 2.3u"m"
a + b

# %%
# Example 2: different units, same physical dimension — auto-converted
height_m  = 1.75u"m"
height_ft = 5.9u"ft"
height_m + height_ft        # result is in metres

# %%
# Example 3: different dimensions — caught at compile time, not runtime
# Uncomment the next line to see the error:
# 1.0u"m" + 1.0u"s"
#
# DimensionError: 𝐋 and 𝐓 are not dimensionally compatible
#
# In NicheMapR (R + Fortran), this kind of mistake silently produces a wrong
# number. Here it is a hard error — the code cannot run.

# %%
# Temperature units handle the offset correctly (°C ≠ K/shift — they differ
# in both scale and origin for absolute values, but ΔT is still ΔT):
T_celsius = 20.0u"°C"
uconvert(u"K", T_celsius)   # 293.15 K

ΔT = 5.0u"K"                # a temperature *difference* — no offset needed
T_celsius + ΔT              # 25 °C

# =============================================================================
# PART 2 — Multiple dispatch: FluidProperties.jl
# =============================================================================
#
# Multiple dispatch is Julia's central design pattern. A function can have many
# *methods*, each specialised for a different combination of argument types.
# The compiler selects the right method at compile time and generates native
# code for it — no runtime branching, no virtual dispatch overhead.
#
# This is very different from R's S3/S4 dispatch (which is runtime and
# approximate) or object-oriented languages where dispatch is on the first
# argument only. In Julia, *every* argument participates in dispatch.
#
# FluidProperties.jl uses this to provide swappable vapour pressure equations
# with a single, stable function name: vapour_pressure(equation, temperature).

# %%
using FluidProperties

# Three equations, one function name:
T = 20.0u"°C"
vapour_pressure(Teten(), T)   # fast, low accuracy (one exp call)
vapour_pressure(GoffGratch(), T)  # standard — used in most meteorology
vapour_pressure(Huang(), T)   # high accuracy, -100 to 100 °C

# %%
# Inspect all available methods — Julia makes its dispatch table transparent:
methods(vapour_pressure)

# %%
# Adding your own equation — without touching the FluidProperties source code.
#
# Because Julia dispatches on types, any package user can extend a function
# simply by defining a new method for a new type. The package does not need
# to know about it. No subclassing, no monkey-patching, no modification of
# installed files.
#
# Here is a deliberately silly example: vapour pressure is always 1000 Pa,
# regardless of temperature. (Useful for testing, not for weather.)

struct AlwaysOnekPa <: VapourPressureEquation end

function FluidProperties.vapour_pressure(::AlwaysOnekPa, T)
    return 1000.0u"Pa"
end

FluidProperties.vapour_pressure(AlwaysOnekPa(), 20.0u"°C")   # → 1000.0 Pa
FluidProperties.vapour_pressure(AlwaysOnekPa(), -40.0u"°C")  # → still 1000.0 Pa — it's silly

# %%
# Check that the dispatch table now includes our new method:
methods(vapour_pressure)
# Notice AlwaysOnekPa appears alongside Teten, GoffGratch, Huang, VPLookupTable —
# all on equal footing. The package has no idea we did this.

# %%
# Because AlwaysOnekPa <: VapourPressureEquation, it works anywhere the other
# equations work — including the strip_Pa helper we are about to define, and
# in principle as the vapour_pressure_equation argument inside MicroModel.
# The compiler generates a fully specialised, optimised code path for it
# just as it does for the built-in equations.

# %%
# The VapourPressureLookup wraps any equation in a precomputed table for speed in
# tight loops. It composes with the same function — no new API to learn:
lut = VapourPressureLookup(GoffGratch())
vapour_pressure(lut, T)     # linear interpolation, no transcendental calls

# %%
# Plot all three over the temperature range relevant to microclimate work.
# The differences matter most at freezing (phase transition) and high temperatures.

# =============================================================================
# PART 3 — Solar radiation: SolarRadiation.jl
# =============================================================================
#
# Mont Aigoual (44.122°N, 3.581°E, 1567 m) is the meteorological summit of
# the Cévennes — one of the wettest peaks in France, with dramatic differences
# in solar exposure between its north and south flanks.
#
# SolarRadiation.jl implements the McCullough & Porter (1971) spectral model:
# it integrates direct and diffuse irradiance across 111 wavelength bands,
# accounting for Rayleigh scattering, aerosol extinction, ozone absorption,
# and water vapour. The result matches the NicheMapR solar model to < 0.01%.

# %%
using SolarRadiation, Unitful, Dates

# Terrain parameters for the Mont Aigoual summit
latitude  = 44.122u"°"
longitude = 3.581u"°"
elevation = 1567.0u"m"

# Atmospheric pressure at 1567 m (barometric formula)
atmospheric_pressure = Microclimate.atmospheric_pressure(elevation)

flat_terrain = SolarTerrain(;
    elevation,
    horizon_angles    = fill(0.0u"°", 32),  # flat horizon (32 azimuths)
    slope             = 0.0u"°",
    aspect            = 180.0u"°",
    albedo            = 0.15,
    atmospheric_pressure,
    latitude,
    longitude,
)

# South-facing slope — same summit, tilted 20°
south_terrain = SolarTerrain(;
    elevation,
    horizon_angles    = fill(0.0u"°", 32),
    slope             = 20.0u"°",
    aspect            = 180.0u"°",          # due south
    albedo            = 0.15,
    atmospheric_pressure,
    latitude,
    longitude,
)

solar_model = SolarProblem()   # default spectral parameters
hours = 0.0:1.0:23.0

# %%
# Compute for four key days: solstices and equinoxes
days      = [80.0, 172.0, 264.0, 355.0]
day_names = ["Spring equinox (Mar 21)", "Summer solstice (Jun 21)",
             "Autumn equinox (Sep 23)", "Winter solstice (Dec 21)"]

flat_out  = solar_radiation(solar_model; solar_terrain = flat_terrain,  days, hours)
south_out = solar_radiation(solar_model; solar_terrain = south_terrain, days, hours)

n_h = length(hours)
n_d = length(days)

# Reshape output: rows = hours, cols = days
flat_global  = reshape(ustrip.(u"W/m^2", flat_out.global_horizontal),  n_h, n_d)
south_global = reshape(ustrip.(u"W/m^2", south_out.global_terrain),    n_h, n_d)

using CairoMakie

fig = Figure(size = (1000, 450))
colors = [:royalblue, :gold, :darkorange, :steelblue4]

ax1 = Axis(fig[1, 1]; title = "Flat terrain",
           xlabel = "Hour of day", ylabel = "Global radiation (W/m²)")
ax2 = Axis(fig[1, 2]; title = "South-facing slope (20°)",
           xlabel = "Hour of day", ylabel = "Global radiation (W/m²)")

for (i, name) in enumerate(day_names)
    lines!(ax1, collect(hours), flat_global[:, i];  label = name, color = colors[i])
    lines!(ax2, collect(hours), south_global[:, i]; label = name, color = colors[i])
end

axislegend(ax1; position = :lt, framevisible = false)
linkyaxes!(ax1, ax2)
fig

# %%
# Key observation: in winter the south-facing slope receives dramatically more
# radiation than the flat summit — this drives the snowpack differences we will
# see in the full microclimate simulation.

# Difference at solar noon, winter solstice:
noon_flat  = flat_global[13, 4]   # hour 12, day index 4
noon_south = south_global[13, 4]
println("Winter noon: flat $(round(Int, noon_flat)) W/m² vs south slope $(round(Int, noon_south)) W/m²")

# =============================================================================
# PART 4 — Rasters and spatial data: Rasters.jl + RasterDataSources.jl
# =============================================================================
#
# R's terra package represents rasters as objects with a coordinate reference
# system, extent, and resolution — accessed by row/column index or by
# extracting at coordinates. It is powerful, but the indexing model is numeric:
# you get and set values by position, not by named dimension.
#
# Rasters.jl is built on DimensionalData.jl, which gives every raster axis a
# *name* and a *lookup* (the coordinate values along that axis). This means
# you index by what you mean, not by position number:
#
#   R (terra):     elev[150, 200]              # what row/col is that?
#   Julia:         elev[X(Near(3.581)), Y(Near(44.122))]   # exact coordinate
#
# Dimensions are also types, so operations that combine rasters check that
# the dimensions are compatible — the same kind of safety Unitful gives for
# physical units.

# %%
using Rasters, RasterDataSources
using Rasters.Extents: Extent
using Dates

# Download (or load from cache) a small SRTM elevation tile around Mont Aigoual.
# The bounding box covers the summit and surrounding terrain.
area = Extent(X = (3.45, 3.72), Y = (44.00, 44.25))

# lazy = true: the file is memory-mapped — no data is read until you index it.
# This is how Rasters.jl handles datasets too large to hold in RAM.
srtm = Raster(SRTM; extent = area, lazy = true)

# %%
display(srtm)

# %%
# Index by coordinate — no need to know which row/column that is:
summit_elev = srtm[X(Near(3.581)), Y(Near(44.122))]
println("Summit elevation: ", summit_elev, " m")

# Crop to a small subregion around the summit — result is still a Raster:
summit_box = srtm[X(3.52..3.65), Y(44.08..44.18)]
println("Cropped size: ", size(summit_box))

# %%
# Plot the terrain — CairoMakie knows how to display Rasters directly:
fig, ax, plt = heatmap(summit_box;
    colormap = :terrain,
    axis = (aspect = DataAspect(), title = "SRTM elevation — Mont Aigoual region (m)"))
Colorbar(fig[1, 2], plt)

# Mark the three workshop sites
scatter!(ax, [3.520, 3.582, 3.581], [44.143, 44.115, 44.122];
    marker = :circle, color = :white, strokecolor = :black, strokewidth = 1,
    markersize = 10)
fig

# %%
# Terrain analysis with Geomorphometry.jl
# ─────────────────────────────────────────────────────────────────────────────
# The terrain parameters that drive microclimate — slope, aspect, and horizon
# angles — can be computed directly from the SRTM raster. Geomorphometry.jl
# accepts Rasters directly: it reads the CRS to convert degrees → metres for
# the cellsize, so you don't have to think about projection conversions.
#
# In R you would use terrain() from terra, then a separate package for horizon
# angles. Here it is one package, one consistent call style.

using Geomorphometry

# Work on the summit subregion for clarity (the cropped box we made earlier)
# Convert to Float32 — SRTM is stored as Int16, terrain derivatives need floats
dem = Float32.(summit_box)

# Slope — rate of elevation change, degrees (Horn 8-neighbour method by default)
slp = slope(dem)       # returns a Raster with the same X/Y dimensions

# Aspect — compass direction of steepest descent (0° = North, 180° = South)
asp = aspect(dem)

# %%
# Plot all three side by side
fig = Figure(size = (1100, 420))

ax1 = Axis(fig[1, 1]; aspect = DataAspect(), title = "Elevation (m)")
ax2 = Axis(fig[1, 2]; aspect = DataAspect(), title = "Slope (°)")
ax3 = Axis(fig[1, 3]; aspect = DataAspect(), title = "Aspect (°, 0 = N, 180 = S)")

p1 = heatmap!(ax1, summit_box; colormap = :terrain)
p2 = heatmap!(ax2, slp;        colormap = :hot,    colorrange = (0, 45))
p3 = heatmap!(ax3, asp;        colormap = :hsv,    colorrange = (0, 360))

Colorbar(fig[2, 1], p1; vertical = false, label = "m")
Colorbar(fig[2, 2], p2; vertical = false, label = "°")
Colorbar(fig[2, 3], p3; vertical = false, label = "°")

# Mark the summit
for ax in (ax1, ax2, ax3)
    scatter!(ax, [3.581], [44.122]; marker = :star5, color = :white,
             strokecolor = :black, strokewidth = 1, markersize = 12)
end
fig

# %%
# The north/south contrast is immediately visible in the aspect map — the
# main ridge runs roughly east–west, so the southern flank is south-facing
# (≈180°, warm colours) and the northern flank is north-facing (≈0°/360°,
# cool colours). This is what drives the snowpack differences in Part 6.

# %%
# Horizon angles — for each pixel, the maximum elevation angle to terrain
# in each compass direction. A high horizon angle in a direction means
# terrain blocks sun from that direction.
#
# The output is a plain 3D Array: (rows, cols, n_directions).
# We use 32 directions (matching what MicroclimateMapper uses internally).

horizons = horizon_angle(dem; directions = 32)   # degrees above horizontal

println("Horizon angle array size: ", size(horizons), "  (rows × cols × directions)")
println("Shape: $(size(dem,1)) pixels × $(size(dem,2)) pixels × 32 azimuths")

# %%
# Horizon angle maps in the four cardinal directions.
# Direction index: N=1 (0°), E=9 (90°), S=17 (180°), W=25 (270°)
dir_indices = (1, 9, 17, 25)
dir_labels  = ("North (0°)", "East (90°)", "South (180°)", "West (270°)")

clim = (0, maximum(horizons))
fig = Figure(size = (900, 820))
last_p = nothing
for (k, (idx, lbl)) in enumerate(zip(dir_indices, dir_labels))
    row, col = fldmod1(k, 2)
    ax = Axis(fig[row, col]; aspect = DataAspect(), title = "Horizon angle — $lbl")
    slice = Raster(horizons[:, :, idx], dims(dem, (X, Y)))
    last_p = heatmap!(ax, slice; colormap = :hot, colorrange = clim)
end
Colorbar(fig[1:2, 3], last_p; label = "°")
fig

# %%
# Sky view factor — the fraction of the sky hemisphere visible from each pixel.
# SVF = 1 means full open sky; SVF < 1 means terrain is blocking part of the sky.
# Deep valleys have low SVF; ridge tops and summits have SVF close to 1.
# This directly controls how much diffuse radiation a surface receives.

svf = sky_view_factor(dem; directions = 32)

fig = Figure(size = (520, 460))
ax  = Axis(fig[1, 1]; aspect = DataAspect(),
    title  = "Sky view factor — Mont Aigoual\n(1 = full sky, 0 = fully enclosed)")
p   = heatmap!(ax, svf; colormap = :Blues_9, colorrange = (0.8, 1.0))
Colorbar(fig[1, 2], p)
scatter!(ax, [3.581], [44.122]; marker = :star5, color = :white,
         strokecolor = :black, strokewidth = 1, markersize = 12)
fig

# %%
# MicroclimateMapper uses all of this internally:
#   slope(dem)           → SolarTerrain.slope per pixel
#   aspect(dem)          → SolarTerrain.aspect per pixel
#   horizon_angle(dem; directions=32) → SolarTerrain.horizon_angles per pixel
#
# Those terrain parameters feed the SolarRadiation.jl model at each grid cell
# so that direct radiation is correctly adjusted for local topography.
# You have just computed by hand what the raster solver does automatically.

# %%
# RasterDataSources.jl is a catalogue of ready-to-download datasets.
# Each source is a Julia type — you get data by asking for it by type,
# not by remembering a URL or file format:
#
#   Raster(SRTM; extent, ...)            # 90-m global DEM
#   RasterStack(CHELSA{BioClim}; ...)    # 1-km bioclimate
#   RasterStack(TerraClimate{Historical}; ...) # monthly climate timeseries
#   RasterStack(NCEP{SurfaceGauss}; ...) # daily reanalysis
#
# In R you would call a different function or package for each of these,
# with different argument conventions, file formats, and projection handling.
# Here it is a uniform interface — swap the type, get different data.

# %%
# Time dimension example — load a multi-date stack:
# (NCEP data is downloaded by the solver; here we show the interface)
#
# stack = RasterStack(NCEP{SurfaceGauss}; extent = area, year = 2010)
# stack  # → named layers: :air, :rhum, :uwnd, :vwnd, :prate ...
#
# Access by layer name AND time:
# stack[:air][Ti(Date(2010, 1, 15))]          # temperature on Jan 15
# stack[:air][X(Near(3.58)), Y(Near(44.12)), Ti(1)]  # single pixel, first day
#
# In R (terra or stars):
# terra::subset(stack, "air")[ , , 15]        # layer, then numeric time index
# stars::st_get_dimension_values(stack, "time")[15]  # you have to look it up

# %%
# DimensionalData.jl — the core of Rasters.jl
# A raster is just a DimArray: an array whose axes have names and coordinate
# values. This works on any array, not just rasters — it is the same idea as
# xarray in Python, but implemented as a type system feature:
using DimensionalData

temps_da = DimArray(
    rand(24, 10),                           # 24 hours × 10 soil depths
    (Ti(0:23), Dim{:depth}([0,2.5,5,10,15,20,30,50,100,200]u"cm"))  # depth axis with units
)

# Index by name:
temps_da[Ti(12)]                    # all depths at hour 12
temps_da[depth=Near(5u"cm")] # nearest depth to 5 cm, all hours



# =============================================================================
# PART 5 — The Julia microclimate ecosystem
# =============================================================================
#
# Architecture comparison
# ─────────────────────────────────────────────────────────────────────────────
#
# NicheMapR:
#   ┌─────────────────────────────────────────────────────┐
#   │  R (user-facing)                                    │
#   │  micro(), ecto(), endoR() ...                       │
#   │         ↕ .Fortran() / .C()  (hard boundary)        │
#   │  Fortran binary  (precompiled, opaque to R users)   │
#   │  soil heat balance, radiation, vapour pressure ...  │
#   └─────────────────────────────────────────────────────┘
#
#   • Fast because Fortran is compiled ahead of time.
#   • Rigid: changing the physics means editing Fortran and rebuilding.
#   • One large package: solar radiation, soil, snow, organisms — all tangled.
#   • No unit checking anywhere.
#
# Julia ecosystem:
#   ┌────────────────────────────────────────────────────────────────────┐
#   │  MicroclimateMapper.jl  (landscape scale: rasters, points, data)   │
#   │         ↓                                                           │
#   │  Microclimate.jl        (single-point physics solver)               │
#   │    ├── FluidProperties.jl  (air/water properties, vapour pressure)  │
#   │    ├── SolarRadiation.jl   (spectral solar model)                   │
#   │    └── [ODE solver from SciML]                                      │
#   │                                                                      │
#   │  HeatExchange.jl        (organism heat balance — couples to above)  │
#   └────────────────────────────────────────────────────────────────────┘
#   + Rasters.jl, RasterDataSources.jl, DimensionalData.jl (spatial I/O)
#
#   • Fast because Julia compiles every function to native code at first call.
#   • Modular: each package is small, focused, independently testable.
#   • No boundary penalty: packages compose without overhead.
#   • Units checked at compile time — zero runtime cost.
#   • Swapping a sub-model (e.g. vapour pressure equation, snow model) is
#     one keyword argument — the compiler generates a new specialised path.
#
# On Julia's compilation model:
# ─────────────────────────────
# Julia is not interpreted like R. When you call a function, Julia inspects
# the *types* of the arguments, compiles native machine code for that exact
# combination, caches it, and runs it. First call is slow (compilation);
# every call after is Fortran speed.
#
# This is why loops are free in Julia — you do not need to "vectorise" into
# apply() to push work into C. A Julia for-loop compiles to the same native
# code as its vectorised equivalent.
#
# The cost: longer startup time ("time to first plot"). The setup.jl you ran
# yesterday paid that cost so we don't pay it today.



# =============================================================================
# PART 6 — Single-point microclimate simulation
# =============================================================================
#
# We simulate the full microclimate at three sites on the Mont Aigoual massif
# for the winter of 2010 — a year with substantial snowpack at the summit.
# All three sites fall within the same NCEP grid cell (~2.5° resolution), so
# they receive the same large-scale weather forcing. The differences in
# snowpack and soil temperature come entirely from elevation, aspect, and
# terrain-driven radiation corrections — exactly what the model is for.

# %%
using Microclimate, MicroclimateMapper
using Microclimate: example_soil_profile, example_soil_properties_model,
                    example_soil_hydraulic_model
using Rasters
using Rasters: Ti, lookup
using Unitful
using Dates

depths  = [0.0, 2.5, 5.0, 10.0, 15.0, 20.0, 30.0, 50.0, 100.0, 200.0]u"cm"
heights = [0.01, 2.0]u"m"

model = MicroMapModel(;
    micro_model = MicroModel(;
        depths, heights,
        soil_properties_model = example_soil_properties_model(),
        soil_hydraulic_model = example_soil_hydraulic_model(),
        snow_model = SnowModel(),    # enable snowpack
    ),
    dem_source = SRTM,
    weather_source = NCEP{SurfaceGauss},
    surface_albedo_source = 0.15,
    roughness_height_source = 0.004u"m",
)

# Three sites — valley, south slope, summit
points = [
    (3.520, 44.143),   # Camprieu valley  (~900 m)
    (3.582, 44.115),   # South-facing slope (~1200 m)
    (3.581, 44.122),   # Mont Aigoual summit (~1567 m)
]
labels = ["Valley (900 m)", "South slope (1200 m)", "Summit (1567 m)"]

problem = MicroVectorProblem(;
    model,
    points,
    dates = Date(2010, 1, 1):Day(1):Date(2010, 12, 31),
    soil_profile = example_soil_profile(depths),
    init = (;
        soil_moisture = fill(0.25, length(depths)),
        snow_depth = 0.0u"cm",
    ),
)

@time output = solve(problem)
result = strip_to_canonical(output)

# %%
# Snow depth — January through May, daily noon values
ti = lookup(result, Ti)
snow_selector = Where(t -> hour(t) == 12 && month(t) <= 5)
snow_dates = ti[snow_selector]

fig = Figure(size = (900, 400))
ax  = Axis(fig[1, 1];
    title  = "Snow depth at noon — Jan–May 2010",
    xlabel = "Date",
    ylabel = "Snow depth (cm)")

colors = [:black, :firebrick, :royalblue]
for (i, label) in enumerate(labels)
    display(result.snow_depth)
    snow = result.snow_depth[point=i, Ti=snow_selector]
    lines!(ax, snow_dates, collect(snow); label, color = colors[i], linewidth = 1.5)
end
axislegend(ax; position = :rt, framevisible = false)
fig

# %%
# Diurnal temperature profiles — a single day in March
target_date  = Date(2010, 3, 1)
day_idx      = findall(t -> Date(t) == target_date, ti)
hours_of_day = hour.(ti[day_idx])

fig = Figure(size = (1100, 500))
Label(fig[0, 1:2], "Diurnal temperatures — $target_date"; fontsize = 13, halign = :left, tellwidth = false)
ax  = Axis(fig[1, 1]; xlabel = "Hour of day", ylabel = "Temperature (°C)")

# Four temperature variables: soil surface, soil 50 cm, air 1 cm, air 2 m
# Extract each as a (n_points × n_hours) matrix indexed by point then day
extract(layer, dim, idx) =
[collect(layer[Dim{:point}(i), dim, Ti(idx)]) for i in 1:length(labels)]

panels = [
    ("Soil surface", extract(result.soil_temperature, Dim{:depth}(1),  day_idx)),
    ("Soil 50 cm",   extract(result.soil_temperature, Dim{:depth}(8),  day_idx)),
    ("Air 1 cm",     extract(result.air_temperature,  Dim{:height}(1), day_idx)),
    ("Air 2 m",      extract(result.air_temperature,  Dim{:height}(2), day_idx)),
]
cmaps  = [:Oranges, :Purples, :Greens, :Blues]
shades = [0.9, 0.65, 0.45]  # dark → light for valley → slope → summit

group_handles = []
group_titles  = String[]

for (k, (name, series)) in enumerate(panels)
    handles = []
    for (i, _) in enumerate(labels)
        h = lines!(ax, hours_of_day, series[i];
            color = cgrad(cmaps[k])[shades[i]], linewidth = 1.4)
        push!(handles, h)
    end
    push!(group_handles, handles)
    push!(group_titles, name)
end

leg_layout = GridLayout(fig[1, 2])
for (k, (title, handles)) in enumerate(zip(group_titles, group_handles))
    Legend(leg_layout[k, 1], handles, labels;
        title, framevisible = false, labelsize = 10, titlesize = 11,
        titlehalign = :left, rowgap = 2)
end
colsize!(fig.layout, 2, Auto(0.22))
fig

# %%
# Annual soil temperature profiles at the summit — all depths, all hours
# Shallow layers track air temperature closely; deep layers are buffered and lagged.
soil_depth_indices = [1, 3, 4, 7, 8, 9]   # 0, 5, 10, 30, 50, 100 cm
depth_labels       = ["0 cm", "5 cm", "10 cm", "30 cm", "50 cm", "100 cm"]

fig = Figure(size = (1000, 420))
ax  = Axis(fig[1, 1];
    title  = "Annual soil temperatures — summit 2010",
    xlabel = "Date", ylabel = "Soil temperature (°C)")

depth_colors = cgrad(:Spectral, length(soil_depth_indices); categorical = true, rev = true)
for (j, (didx, dlbl)) in enumerate(zip(soil_depth_indices, depth_labels))
    ts = collect(result.soil_temperature[point=3, depth=didx])
    lines!(ax, ti, ts; label = dlbl, color = depth_colors[j], linewidth = 1.0)
end
Legend(fig[1, 2], ax; framevisible = false, title = "Depth")
colsize!(fig.layout, 2, Auto(0.15))
fig

# =============================================================================
# PART 7 — Raster solar radiation over Mont Aigoual
# =============================================================================
#
# [TO BE ADDED — code will go here once raster solar radiation output is
#  wired into MicroclimateMapper. The demo will run SolarRadiation.jl at
#  every SRTM pixel, showing how direct radiation varies with slope and
#  aspect across the massif — the primary driver of the microclimate
#  differences we saw in Part 6.]

# %%
println("Part 7 (raster solar radiation) — coming soon.")



# =============================================================================
# PART 8 — Raster microclimate simulation over Mont Aigoual
# =============================================================================
#
# The raster solver runs the same physics used in Part 6 at every pixel of a
# DEM grid. The output is a 4-D array (X, Y, Ti, depth/height) with the same
# named-dimension access we saw with Rasters.jl in Part 4.
#
# Area: ~0.054° square centred on the summit — 66 × 66 SRTM pixels at 90 m.
# Weather: TerraClimate monthly climatology (no daily weather download needed).
# Snow: disabled — for a faster calculation in the demo.
# Timing: ~80 s on a laptop — 66 × 66 pixels × 12 months × 24 hours =
#         1.25 million individual microclimate solves.
#
# The key story: all pixels share the same TerraClimate grid cell, so the
# spatial pattern in the output comes entirely from terrain — elevation,
# slope, and aspect — exactly as in the three-point comparison.

# %%
using Rasters.Extents: Extent
using Statistics: mean
using Dates

mkpath(joinpath(@__DIR__, "output"))

# ~0.054° box centred on Mont Aigoual summit
area = Extent(X = (3.554, 3.608), Y = (44.095, 44.149))

raster_model = MicroMapModel(;
    micro_model = MicroModel(;
        depths, heights,
        soil_properties_model = example_soil_properties_model(),
        soil_hydraulic_model  = example_soil_hydraulic_model(),
        snow_model            = NoSnow(),   # TerraClimate is monthly — no snow
    ),
    dem_source              = SRTM,
    weather_source          = TerraClimate{Historical},
    surface_albedo_source   = 0.15,
    roughness_height_source = 0.004u"m",
)

raster_problem = MicroRasterProblem(;
    model        = raster_model,
    area,
    dates        = Date(2010, 1, 1):Day(1):Date(2010, 12, 31),
    template     = SRTM,           # native SRTM resolution as the pixel grid
    soil_profile = example_soil_profile(depths),
)

# %%
@time raster_output = solve(raster_problem)

# Strip Unitful units → plain Float64 for NetCDF compatibility
raster_result = strip_to_canonical(raster_output)

# Save — the file can be opened directly in QGIS, R (terra), or Python (xarray)
outpath = joinpath(@__DIR__, "output", "aigoual_2010.nc")
write(outpath, raster_result; force = true)
println("Saved to ", outpath)

# %%
# The output has the same DimensionalData structure as the vector result,
# but with spatial X, Y dimensions instead of a point dimension:
#
#   raster_result.soil_temperature  → (X=66, Y=66, Ti=288, depth=10)
#                                       288 = 12 months × 24 hours
#
# Access a single pixel by coordinate — same syntax as the SRTM raster earlier:
#   raster_result.soil_temperature[X(Near(3.581)), Y(Near(44.122))]
#   raster_result.air_temperature[X(Near(3.520)), Y(Near(44.143))]

# Soil surface temperature in July at four times of day.
# The diurnal cycle of aspect-driven heating is most visible in summer.
times_of_day = [6, 9, 12, 15]
time_labels  = ["6 am", "9 am", "Noon", "3 pm"]

jul_surfs = [
    let s = raster_result.soil_temperature[Ti=Where(t -> month(t) == 7 && hour(t) == h), depth=1]
        mean(s; dims = Ti)[Ti=1]
    end
    for h in times_of_day
]

# %%
# Map: July soil surface temperature at four times of day.
# At 6 am south-facing slopes are barely warmer than north; by noon the contrast
# is at its peak; by 3 pm the west-facing slopes take over.

clim = (minimum(minimum.(jul_surfs)), maximum(maximum.(jul_surfs)))
fig = Figure(size = (1000, 900))
for (k, (surf, lbl)) in enumerate(zip(jul_surfs, time_labels))
    row, col = fldmod1(k, 2)
    ax = Axis(fig[row, col]; aspect = DataAspect(),
        title = "July soil surface — $lbl",
        xlabel = "Longitude", ylabel = col == 1 ? "Latitude" : "")
    last_p = heatmap!(ax, surf; colormap = Reverse(:RdBu), colorrange = clim, interpolate = false)
    if col == 2
        Colorbar(fig[row, 3], last_p; label = "°C")
    end
end
fig

# %%
# Annual range: how much does the soil surface warm up between winter and summer?
# Use noon values for a fair like-for-like comparison.
jan_surf = let s = raster_result.soil_temperature[Ti=Where(t -> month(t) == 1 && hour(t) == 12), depth=1]
    mean(s; dims = Ti)[Ti=1]
end
jul_surf = jul_surfs[3]   # noon panel from the four-panel plot above
annual_range = jul_surf .- jan_surf

fig2 = Figure(size = (520, 460))
ax = Axis(fig2[1, 1]; aspect = DataAspect(),
    title  = "Soil surface annual range (noon)\nJuly − January 2010 (°C)",
    xlabel = "Longitude", ylabel = "Latitude")
p = heatmap!(ax, annual_range; colormap = :plasma, interpolate = false)
Colorbar(fig2[1, 2], p; label = "°C")
fig2

# %%
# Compare the summit pixel time series against the valley pixel —
# same DimensionalData indexing we used for the SRTM raster in Part 4.
summit_Tsoil = raster_result.soil_temperature[X=Near(3.581), Y=Near(44.122), depth=1]
valley_Tsoil = raster_result.soil_temperature[X=Near(3.520), Y=Near(44.143), depth=1]

fig3 = Figure(size = (900, 380))
ax = Axis(fig3[1, 1];
    title  = "Surface soil temperature — summit vs valley (2010 climatology)",
    xlabel = "Time step (month × hour)",
    ylabel = "Soil surface temperature (°C)")
lines!(ax, collect(summit_Tsoil); label = "Summit (1567 m)", color = :royalblue)
lines!(ax, collect(valley_Tsoil); label = "Valley (900 m)",  color = :black)
axislegend(ax; position = :lt, framevisible = false)
fig3
