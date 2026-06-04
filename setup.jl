println("\nCompiling packages (this takes a few minutes)...")

using Unitful
using CairoMakie
using Rasters, RasterDataSources
using Dates

using FluidProperties
using SolarRadiation
using Geomorphometry
using Microclimate
using Microclimate: example_soil_profile, example_soil_properties_model,
                    example_soil_hydraulic_model
using MicroclimateMapper

println("✓ All packages loaded and compiled.")

# Change this path if you need to!
data_dir = joinpath(homedir(), "spatial_data")
mkpath(data_dir)
ENV["RASTERDATASOURCES_PATH"] = data_dir

# ---------------------------------------------------------------------------
# Step 5: Warm up the solver JIT with a tiny solve
# ---------------------------------------------------------------------------
# The microclimate ODE solver uses SciML under the hood. The first call
# to `solve` triggers specialised compilation for the problem type.
# We run a one-point, one-year solve here so it is already compiled tomorrow.

println("\nWarming up the microclimate solver (may take 1–2 minutes)...")

depths  = [0.0, 2.5, 5.0, 10.0, 15.0, 20.0, 30.0, 50.0, 100.0, 200.0]u"cm"
heights = [0.01, 2.0]u"m"

warmup_model = MicroMapModel(;
    micro_model = MicroModel(;
        depths, heights,
        soil_properties_model = example_soil_properties_model(),
        soil_hydraulic_model  = example_soil_hydraulic_model(),
        snow_model            = SnowModel(),
    ),
    dem_source              = SRTM,
    weather_source          = NCEP{SurfaceGauss},
    surface_albedo_source   = 0.15,
    roughness_height_source = 0.004u"m",
)

# Mont Aigoual summit — the point we use throughout the workshop
summit = (3.581, 44.122)

warmup_problem = MicroVectorProblem(;
    model        = warmup_model,
    points       = [summit],
    dates        = Date(2010, 1, 1):Day(1):Date(2010, 12, 31),
    soil_profile = example_soil_profile(depths),
    init         = (;
        soil_moisture = fill(0.25, length(depths)),
        snow_depth    = 0.0u"cm",
    ),
)

# This also downloads NCEP 2010 data and SRTM for the Cévennes region
# (~100 MB total) if not already cached.
elapsed = @elapsed output = solve(warmup_problem)
println("✓ Solver warm-up complete in $(round(elapsed; digits=1)) s.")
println("  (Future solves at this site will take ~12 s.)")

# ---------------------------------------------------------------------------
# Step 6: Quick smoke test
# ---------------------------------------------------------------------------
result = strip_to_canonical(output)

@assert size(result.soil_temperature, 1) == 1    "unexpected point count"
@assert size(result.soil_temperature, 2) == 8760 "expected 8760 hourly steps"
@assert size(result.soil_temperature, 3) == length(depths)

println("\n✓ Output looks correct.")
println("  soil_temperature size: ", size(result.soil_temperature),
        "  (points × hours × depths)")

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
println("""

╔══════════════════════════════════════════════════════════════╗
║  Setup complete — you are ready for tomorrow's workshop!     ║
║                                                              ║
║  To start the workshop:                                      ║
║    1. Open VS Code                                           ║
║    2. Open the workshop folder                               ║
║    3. Open workshop.jl                                       ║
╚══════════════════════════════════════════════════════════════╝
""")
