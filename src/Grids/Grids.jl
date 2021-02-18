module Grids

export
    Center, Face,
    AbstractTopology, Periodic, Bounded, Flat, topology,
    AbstractGrid,
    AbstractCartesianGrid, RegularCartesianGrid, VerticallyStretchedCartesianGrid,
    xnode, ynode, znode, xnodes, ynodes, znodes, nodes,
    xC, xF, yC, yF, zC, zF

import Base: size, length, eltype, show

import Oceananigans: short_show

using Oceananigans
using Oceananigans.Architectures

using OffsetArrays

#####
##### Abstract types
#####

"""
    Center

A type describing the location at the center of a grid cell.
"""
struct Center end

"""
	Face

A type describing the location at the face of a grid cell.
"""
struct Face end

"""
    AbstractTopology

Abstract supertype for grid topologies.
"""
abstract type AbstractTopology end

"""
    Periodic

Grid topology for periodic dimensions.
"""
struct Periodic <: AbstractTopology end

"""
    Bounded

Grid topology for bounded dimensions. These could be wall-bounded dimensions
or dimensions
"""
struct Bounded <: AbstractTopology end

"""
    Flat

Grid topology for flat dimensions, generally with one grid point, along which the solution
is uniform and does not vary.
"""
struct Flat <: AbstractTopology end

"""
    AbstractGrid{FT, TX, TY, TZ}

Abstract supertype for grids with elements of type `FT` and topology `{TX, TY, TZ}`.
"""
abstract type AbstractGrid{FT, TX, TY, TZ} end

"""
    AbstractCartesianGrid{FT, TX, TY, TZ}

Abstract supertype for grids with elements of type `FT` and topology `{TX, TY, TZ}`.
"""
abstract type AbstractCartesianGrid{FT, TX, TY, TZ} <: AbstractGrid{FT, TX, TY, TZ} end

Base.eltype(::AbstractGrid{FT}) where FT = FT
Base.size(grid::AbstractGrid) = (grid.Nx, grid.Ny, grid.Nz)
Base.length(grid::AbstractGrid) = (grid.Lx, grid.Ly, grid.Lz)

halo_size(grid) = (grid.Hx, grid.Hy, grid.Hz)

topology(::AbstractGrid{FT, TX, TY, TZ}) where {FT, TX, TY, TZ} = (TX, TY, TZ)
topology(grid, dim) = topology(grid)[dim]

include("grid_utils.jl")
include("input_validation.jl")
include("regular_cartesian_grid.jl")
include("vertically_stretched_cartesian_grid.jl")

end
