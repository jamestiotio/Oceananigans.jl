using Statistics
using JLD2
using Printf
using Oceananigans
using Oceananigans.Units

using Oceananigans.Distributed
using Oceananigans.Fields: interpolate, Field
using Oceananigans.Advection: VelocityStencil
using Oceananigans.Architectures: arch_array
using Oceananigans.Coriolis: HydrostaticSphericalCoriolis
using Oceananigans.Coriolis: WetCellEnstrophyConservingScheme
using Oceananigans.BoundaryConditions
using Oceananigans.ImmersedBoundaries: inactive_node, peripheral_node
using CUDA: @allowscalar
using Oceananigans.Operators
using Oceananigans.Operators: Δzᵃᵃᶜ
using Oceananigans: prognostic_fields

using MPI
MPI.Init()

#####
##### Grid
#####

child_arch = GPU()

comm   = MPI.COMM_WORLD
rank   = MPI.Comm_rank(comm)
Nranks = MPI.Comm_size(comm)

topo = (Periodic, Bounded, Bounded)
arch = MultiArch(child_arch; topology = topo, ranks=(Nranks, 1, 1))

reference_density = 1029

latitude = (-75, 75)

# 0.25 degree resolution
Nx = 1440
Ny = 600
Nz = 48

N = (Nx, Ny, Nz)

const Nyears  = 10
const Nmonths = 12 
const thirty_days = 30days

output_prefix = "near_global_lat_lon_$(Nx)_$(Ny)_$(Nz)_fine"
pickup_file   = false 

#####
##### Load forcing files and inital conditions from ECCO version 4
##### https://ecco.jpl.nasa.gov/drive/files
##### Bathymetry is interpolated from ETOPO1 https://www.ngdc.noaa.gov/mgg/global/
#####

using DataDeps

path = "https://github.com/CliMA/OceananigansArtifacts.jl/raw/ss/new_hydrostatic_data_after_cleared_bugs/quarter_degree_near_global_input_data/"

datanames = ["z_faces-50-levels",
             "bathymetry-1440x600",
             "temp-1440x600-latitude-75",
             "salt-1440x600-latitude-75",
             "tau_x-1440x600-latitude-75",
             "tau_y-1440x600-latitude-75",
             "initial_conditions"]

dh = DataDep("quarter_degree_near_global_lat_lon",
    "Forcing data for global latitude longitude simulation",
    [path * data * ".jld2" for data in datanames]
)

DataDeps.register(dh)

datadep"quarter_degree_near_global_lat_lon"

files = [:file_z_faces, :file_bathymetry, :file_temp, :file_salt, :file_tau_x, :file_tau_y, :file_init]
for (data, file) in zip(datanames, files)
    datadep_path = @datadep_str "quarter_degree_near_global_lat_lon/" * data * ".jld2"
    @eval $file = jldopen($datadep_path)
end

using Oceananigans.Distributed: partition_global_array

bathymetry = file_bathymetry["bathymetry"]

τˣ = zeros(Nx, Ny, Nmonths)
τʸ = zeros(Nx, Ny, Nmonths)
T★ = zeros(Nx, Ny, Nmonths)
S★ = zeros(Nx, Ny, Nmonths)

# Files contain 1 year (1992) of 12 monthly averages
τˣ = file_tau_x["field"] ./ reference_density
τʸ = file_tau_y["field"] ./ reference_density
T★ = file_temp["field"] 
S★ = file_salt["field"] 

# Stretched faces taken from ECCO Version 4 (50 levels in the vertical)
z_faces = file_z_faces["z_faces"][3:end]

# A spherical domain
@show underlying_grid = LatitudeLongitudeGrid(arch,
                                              size = (Nx, Ny, Nz),
                                              longitude = (-180, 180),
                                              latitude = latitude,
                                              halo = (5, 5, 5),
                                              z = z_faces,
                                              precompute_metrics = true)

nx, ny, nz = size(underlying_grid)
bathymetry = bathymetry[1 + nx * rank : (rank + 1) * nx, :]

grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bathymetry))

τˣ = arch_array(child_arch, - τˣ[1 + nx * rank : (rank + 1) * nx, :, :])
τʸ = arch_array(child_arch, - τʸ[1 + nx * rank : (rank + 1) * nx, :, :])

target_sea_surface_temperature = T★ = arch_array(child_arch, T★[1 + nx * rank : (rank + 1) * nx, :, :])
target_sea_surface_salinity    = S★ = arch_array(child_arch, S★[1 + nx * rank : (rank + 1) * nx, :, :])

#####
##### Physics and model setup
#####

νz = 5e-3
κz = 1e-4

convective_adjustment  = ConvectiveAdjustmentVerticalDiffusivity(convective_κz = 0.2, convective_νz = 0.2)
vertical_diffusivity   = VerticalScalarDiffusivity(VerticallyImplicitTimeDiscretization(), ν=νz, κ=κz)
     
tracer_advection   = WENO(underlying_grid)
momentum_advection = VectorInvariant(vorticity_scheme  = WENO(), 
                                     divergence_scheme = WENO(), 
                                     vertical_scheme   = WENO(underlying_grid)) 

#####
##### Boundary conditions / time-dependent fluxes 
#####

@inline current_time_index(time, tot_months)     = mod(unsafe_trunc(Int32, time / thirty_days), tot_months) + 1
@inline next_time_index(time, tot_months)        = mod(unsafe_trunc(Int32, time / thirty_days) + 1, tot_months) + 1
@inline cyclic_interpolate(u₁::Number, u₂, time) = u₁ + mod(time / thirty_days, 1) * (u₂ - u₁)

Δz_top    = @allowscalar Δzᵃᵃᶜ(1, 1, grid.Nz, grid)
Δz_bottom = @allowscalar Δzᵃᵃᶜ(1, 1, 1, grid)

@inline function surface_wind_stress(i, j, grid, clock, fields, τ)
    time = clock.time
    n₁ = current_time_index(time, Nmonths)
    n₂ = next_time_index(time, Nmonths)

    @inbounds begin
        τ₁ = τ[i, j, n₁]
        τ₂ = τ[i, j, n₂]
    end

    return cyclic_interpolate(τ₁, τ₂, time)
end

u_wind_stress_bc = FluxBoundaryCondition(surface_wind_stress, discrete_form = true, parameters = τˣ)
v_wind_stress_bc = FluxBoundaryCondition(surface_wind_stress, discrete_form = true, parameters = τʸ)

# Linear bottom drag:
μ = 0.001 # m s⁻¹

@inline u_bottom_drag(i, j, grid, clock, fields, μ) = @inbounds - μ * fields.u[i, j, 1]
@inline v_bottom_drag(i, j, grid, clock, fields, μ) = @inbounds - μ * fields.v[i, j, 1]
@inline u_immersed_bottom_drag(i, j, k, grid, clock, fields, μ) = @inbounds - μ * fields.u[i, j, k] 
@inline v_immersed_bottom_drag(i, j, k, grid, clock, fields, μ) = @inbounds - μ * fields.v[i, j, k] 

u_immersed_bc = ImmersedBoundaryCondition(bottom = FluxBoundaryCondition(u_immersed_bottom_drag, discrete_form = true, parameters = μ))
v_immersed_bc = ImmersedBoundaryCondition(bottom = FluxBoundaryCondition(v_immersed_bottom_drag, discrete_form = true, parameters = μ))

u_bottom_drag_bc = FluxBoundaryCondition(u_bottom_drag, discrete_form = true, parameters = μ)
v_bottom_drag_bc = FluxBoundaryCondition(v_bottom_drag, discrete_form = true, parameters = μ)

@inline function surface_temperature_relaxation(i, j, grid, clock, fields, p)
    time = clock.time

    n₁ = current_time_index(time, Nmonths)
    n₂ = next_time_index(time, Nmonths)

    @inbounds begin
        T★₁ = p.T★[i, j, n₁]
        T★₂ = p.T★[i, j, n₂]
        T_surface = fields.T[i, j, grid.Nz]
    end

    T★ = cyclic_interpolate(T★₁, T★₂, time)
                                
    return p.λ * (T_surface - T★)
end

@inline function surface_salinity_relaxation(i, j, grid, clock, fields, p)
    time = clock.time

    n₁ = current_time_index(time, Nmonths)
    n₂ = next_time_index(time, Nmonths)

    @inbounds begin
        S★₁ = p.S★[i, j, n₁]
        S★₂ = p.S★[i, j, n₂]
        S_surface = fields.S[i, j, grid.Nz]
    end

    S★ = cyclic_interpolate(S★₁, S★₂, time)
                                
    return p.λ * (S_surface - S★)
end

T_surface_relaxation_bc = FluxBoundaryCondition(surface_temperature_relaxation,
                                                discrete_form = true,
                                                parameters = (λ = Δz_top / 7days, T★ = target_sea_surface_temperature))

S_surface_relaxation_bc = FluxBoundaryCondition(surface_salinity_relaxation,
                                                discrete_form = true,
                                                parameters = (λ = Δz_top / 7days, S★ = target_sea_surface_salinity))

u_bcs = FieldBoundaryConditions(bottom = u_bottom_drag_bc, immersed = u_immersed_bc, top = u_wind_stress_bc)
v_bcs = FieldBoundaryConditions(bottom = v_bottom_drag_bc, immersed = v_immersed_bc, top = v_wind_stress_bc)
T_bcs = FieldBoundaryConditions(top = T_surface_relaxation_bc)
S_bcs = FieldBoundaryConditions(top = S_surface_relaxation_bc)

using Oceananigans.BuoyancyModels: g_Earth
using Oceananigans.Grids: min_Δx, min_Δy

Δt  = 10minutes  # probably we can go to 10min or 15min?
CFL = 0.7
wave_speed = sqrt(g_Earth * grid.Lz)
Δg         = 1 / sqrt(1 / min_Δx(grid)^2 + 1 / min_Δy(grid)^2)
@show substeps = Int(ceil(2 * Δt / (CFL / wave_speed * Δg)))

free_surface = SplitExplicitFreeSurface(; substeps)
buoyancy     = SeawaterBuoyancy(equation_of_state=LinearEquationOfState())
closure      = (vertical_diffusivity, convective_adjustment)
coriolis     = HydrostaticSphericalCoriolis(scheme = WetCellEnstrophyConservingScheme())

model = HydrostaticFreeSurfaceModel(; grid,
                                      free_surface,
                                      momentum_advection, tracer_advection,
                                      coriolis,
                                      buoyancy,
                                      tracers = (:T, :S),
                                      closure,
                                      boundary_conditions = (u=u_bcs, v=v_bcs, T=T_bcs, S=S_bcs)) 

#####
##### Initial condition:
#####

u, v, w = model.velocities
η = model.free_surface.η
T = model.tracers.T
S = model.tracers.S

@info "Reading initial conditions"
T_init = file_init["T"][1 + nx * rank : (rank + 1) * nx, :, :]
S_init = file_init["S"][1 + nx * rank : (rank + 1) * nx, :, :]

set!(model, T=T_init, S=S_init)
fill_halo_regions!(T)
fill_halo_regions!(S)

@info "model initialized"

#####
##### Simulation setup
#####

simulation = Simulation(model, Δt = Δt, stop_iteration = stop_time = Nyears*years)

start_time = [time_ns()]

using Oceananigans.Utils 

function progress(sim)
    wall_time = (time_ns() - start_time[1]) * 1e-9

    u = sim.model.velocities.u
    T = sim.model.tracers.T

    @info @sprintf("Time: % 12s, iteration: %d, max(|u|): %.2e ms⁻¹, max(|T|): %.2e ms⁻¹, wall time: %s", 
                    prettytime(sim.model.clock.time),
                    sim.model.clock.iteration, maximum(abs, u), maximum(abs, T),
                    prettytime(wall_time))

    start_time[1] = time_ns()

    return nothing
end

simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))

u, v, w = model.velocities
T = model.tracers.T
S = model.tracers.S
η = model.free_surface.η

output_fields = (; u, v, T, S, η)
save_interval = 5days

# simulation.output_writers[:surface_fields] = JLD2OutputWriter(model, (; u, v, T, S, η),
#                                                               schedule = TimeInterval(save_interval),
#                                                               filename = output_prefix * "_surface",
#                                                               indices = (:, :, grid.Nz),
#                                                               overwrite_existing = true)

# simulation.output_writers[:checkpointer] = Checkpointer(model,
#                                                         schedule = TimeInterval(1year),
#                                                         prefix = output_prefix * "_checkpoint",
#                                                         overwrite_existing = true)

# Let's goo!
@info "Running with Δt = $(prettytime(simulation.Δt))"

run!(simulation, pickup = pickup_file)

jldsave("variables$rank.jld2", u = u, v = v, w = w, T = T, S = S, η = η, free_surface = model.free_surface, timestepper = model.timestepper)

@info """
    Simulation took $(prettytime(simulation.run_wall_time))
    Free surface: $(typeof(model.free_surface).name.wrapper)
    Time step: $(prettytime(Δt))
"""
