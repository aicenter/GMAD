module Models

using NearestNeighbors
using StatsBase
using Statistics
using LinearAlgebra

using Random
using Flux
using ImageTransformations
using MLDataPattern
using ProgressMeter: Progress, next!

include("utils/utils.jl")
include("utils/two-stage.jl")
include("utils/losses.jl")
include("utils/nn_builders.jl")

include("knn.jl")
include("pidforest.jl")
include("GANomaly.jl")
include("SkipGANomaly.jl")
include("skmodels.jl")
include("pyodmodels.jl")
include("tabular_flows.jl")
include("vae.jl")
include("aae.jl")
include("adVAE.jl")
include("gan.jl")

# this contains dependencies from vae and aae
include("utils/vae_utils.jl")

end
