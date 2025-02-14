
using Parameters, QuantEcon, CSV, StatsBase
using NLsolve, Dierckx, Plots, Distributions, ArgParse
using FastGaussQuadrature, BasisMatrices, Roots
using DelimitedFiles, LinearAlgebra
using SparseArrays, Random
using Distributed, DataFrames
using SharedArrays
using LinearAlgebra



## Convert 1-dimensional index to N-dimensional index
function dim1to2(N::Int64, k::Int)
    i = mod(k, N)
    s = div(k, N) + 1
    if i == 0
        i = N
        s = s - 1
    end
    return i, s
end

function dim1toMultiple(dim_vec, indx)
    len = length(dim_vec)
    N = Int(prod(dim_vec))
    ans = ones(Int, len)
    for i in reverse(1:len)
        N = Int(N/dim_vec[i])
        indx, ans[i] = dim1to2(N, indx)
    end
    return ans
end



## computes productivity process by approximating AR(1) + iid shock
# Np: number of permanent shocks
# Nt: number of transitory shocks
# Ns: number of states without iid shocks
# For the stochastic process in the non-iid case
# (1) persistence is ρ_p
# (2) standard deviation is σ_p
# For the stochastic process in the iid case
# (1) permanent persistence is ρ_p
# (2) permanent standard deviation is σ_p
# (3) transitory standard deviation is σ_e
function computeProductivityProcess(ρ_p, σ_p, σ_e, Np, Nt, Ns, iid)
    if iid
        # The permanent stochastic part
        mc = rouwenhorst(Np, ρ_p, σ_p, 0.)::QuantEcon.MarkovChain{Float64,Array{Float64,2},StepRangeLen{Float64,Base.TwicePrecision{Float64},Base.TwicePrecision{Float64}}}
        P1 = mc.p
        e1 = mc.state_values
        ## The transitory stochastic part
        nodes, weights = gausshermite(Nt)::Tuple{Array{Float64,1},Array{Float64,1}}
        P2 = repeat(weights' / sqrt(pi), Nt) #adjust weights by sqrt(π)
        e2 = sqrt(2) * σ_e * nodes
        # Combine the permanent part and the transitory part
        P = kron(P1, P2) #kron combines matrixies multiplicatively
        e = kron(e1, ones(Nt)) + kron(ones(Np), e2) #e is log productivity
        return MarkovChain(P, e)
    else
        # rouwenhorst(N, ρ, σ, μ)
        # N: Number of points in markov process
        # Process: y(t) = μ + ρ⋅y(t-1) + ε(t), ε(t) ∼ N(0, σ^2)
        return rouwenhorst(Ns, ρ_p, σ_p, 0.)::QuantEcon.MarkovChain{Float64,Array{Float64,2},StepRangeLen{Float64,Base.TwicePrecision{Float64},Base.TwicePrecision{Float64}}}
    end
end



## Computes agrid with Na points with more mass near borrowing constraint.
# "curv" parameter controls how dense the grid points are located around the borrowing constraint.
function construct_agrid(a_min, a_max, Na, curv = 1.7)
    a_grid = zeros(Na)
    a_grid[1] = a_min
    for i in 2:Na
        a_grid[i] = a_min  + (a_max - a_min) * ((i - 1.0) / (Na - 1.0)) ^ curv
    end
    return a_grid
end



@with_kw mutable struct HAmodel
    ## Different Calibration
    σ_str = "h"
    γ_str = "h"
    ## Define control booleans
    yearly::Bool = true
    iid::Bool = true
    from_zero::Bool = false
    gain::Int64 = 2
    ## Define paths
    yearly_str::String = if yearly "yearly" else "quarterly" end
    iid_str::String = if iid "iid" else "noiid" end
    from_str::String = if from_zero "from_zeros" else "from_rational_RA" end
    gain_str::String = if (gain == 1) "gain_0.001" elseif (gain == 2) "gain_0.005" elseif (gain == 3) "gain_0.01" end
    stat_path::String = "HA/$(yearly_str)/$(iid_str)/stationary"
    lear_path::String = "HA/$(yearly_str)/$(iid_str)/learning/simulations/$(from_str)/$(gain_str)"
    irf_path::String = "HA/$(yearly_str)/$(iid_str)/learning/IRFs/$(gain_str)" ## Calibration
    σ::Float64 = if σ_str == "h" 2.0 elseif σ_str == "m" 1.0 elseif σ_str == "l" 0.5 end
    γ::Float64 = if γ_str == "h" 2.0 elseif γ_str == "m" 1.0 elseif γ_str == "l" 0.5 end
    β::Float64 = 0.99#readdlm("../data/$(stat_path)/calibration/beta.csv")[1]
    ρ::Float64 = (yearly) * (0.95 ^ 4) + (!yearly) * (0.95)
    σ_ϵ::Float64 = (yearly) * (0.014) + (!yearly) * (0.007)
    K2Y::Float64 = (yearly) * (10.26 / 4) + (!yearly) * (10.26)
    α::Float64 = 0.36
    δ::Float64 = (yearly) * (0.1) + (!yearly) * (0.025)
    χ::Float64 = 1.1#readdlm("../data/$(stat_path)/calibration/chi.csv")[1]
    γ_gain::Function = t -> ((gain == 1) * (0.001) + (gain == 2) * (0.005) + (gain == 3) * (0.01))
    ## Steady state values
    ā::Float64 = -Inf
    r̄::Float64 = α * inv(K2Y) - δ
    w̄::Float64 = (1 - α) * (K2Y) ^ (α / (1 - α))
    n̄::Float64 = 1 / 3
    ## MarkovChain for the state variable s
    ρ_p::Float64 = (yearly) * (0.9695) + (!yearly) * (0.9923) #persistence
    σ_p::Float64 = (yearly) * sqrt(0.0384) + (!yearly) * (0.0983) #permanent shock standard deviation
    σ_e::Float64 = sqrt(0.053) #transitory shock standard deviation
    Np::Int64 = 7 #number of states for permanent shocks
    Nt::Int64 = 3 #number of states for transitory shocks
    Ns::Int64 = 11 #number of states without iid shocks
    mc::MarkovChain = computeProductivityProcess(ρ_p, σ_p, σ_e, Np, Nt, Ns, iid)
    P::Matrix{Float64} = mc.p
    A::Vector{Float64} = exp.(mc.state_values)
    S::Int64 = length(A)
    N_ϕ::Int64 = 50
    ## Environment variables
    a_min::Float64 = 0.
    a_max::Float64 = (yearly) * (50.) + (!yearly) * (100.)
    Na::Int64 = 150 #number of points in the asset grid for spline
    ϕ_min::Float64 = -0.001
    ϕ_max::Float64 = 0.001
    N::Int64 = 5000
    k_spline::Int64 = 3
    c_min::Vector{Float64} = similar(A)
    c_min2::Vector{Float64} = similar(A)
    ## Simulation paramters
    T::Int64 = 30_000
    agent_num::Int64 = 100_000
    R̄::Matrix{Float64} = Matrix{Float64}(I,3,3)#Matrreaddlm("../data/RA/$(yearly_str)/rational/$(σ_str)$(γ_str)/R_cov.csv", ',')
    ψ_init::Matrix{Float64} = (from_zero)  * zeros(agent_num, 3) +
                              (!from_zero) * readdlm("../data/RA/$(yearly_str)/rational/$(σ_str)$(γ_str)/psi.csv", ',')' .* ones(agent_num)

    R̄_expanded::Matrix{Float64} = Matrix(I, 7, 7)
    ψ_init_expanded::Matrix{Float64} = (from_zero)  * zeros(agent_num, 7) +
                                       (!from_zero) * vcat(readdlm("../data/RA/$(yearly_str)/rational/$(σ_str)$(γ_str)/psi.csv", ','), zeros(4))' .*
                                       ones(agent_num)
end



## Let r̄ and w̄ be the prices in the steady state
# We want to find the consumption function in the steady state: cf(a, s)
# We need to find c̄(a, s), a′(a, s), and n(a, s) that solve
# 1. c̄(a, s)^{-σ} ≥ β⋅(1 + r̄)⋅(∑_{s'} π(s′|s)⋅c̄(a′(a, s), s′)^{-σ})
# 2. c̄(a, s) + a′(a, s) = (1 + r̄)⋅a + A(s)⋅w̄⋅n(a, s)
# 3. A(s)⋅w̄⋅c̄(a, s)^{-σ} = χ⋅(1 - n(a, s))^γ
# The fixed point for c̄(a, s) is the consumption function in the steady state



## labor function, from labor-leisure choice function
function get_n(w, ϵ, c, σ, χ, γ)
    #n = 1 .- ((w .* ϵ .* c .^ (-σ)) ./ χ) .^ (-1 ./ γ)
    n = (w .* ϵ .* c .^ (-σ) ./ χ) .^ (1 ./ γ)
    return n
end


## For each s, compute the vector of consumptions
#  chosen by the agent if a′ = a = a_min.
function compute_cmin!(para)
  @unpack σ, γ, χ, w̄, r̄, A, S, a_min = para
  for s in 1:S
    function f(logc)
      c = exp.(logc)
      n = get_n(w̄, A[s], c, σ, χ, γ)
      return c .- A[s] .* w̄ .* n .- r̄ .* a_min
    end
    res = nlsolve(f, [0.]; inplace = false, iterations = 100_000)
    para.c_min[s] = exp.(res.zero[1])
  end
end



## Given the previous cf (consumption function), approximate the new cf.
# Use interpolation to approximate the consumption function
# n_con is the number of grid points to interpolate the consumption vector from compute_cmin!
function approximate_c(cf, a′grid::Vector, para::HAmodel)
    @unpack σ, γ, β, χ, r̄, w̄, P, A, S, a_min, k_spline, c_min = para
    n_con = 10
    N_a = length(a′grid)
    #preallocate for speed
    a_grid = zeros(S, n_con + N_a)
    c_grid = zeros(S, n_con + N_a)
    Uc′ = zeros(S)
    ## For each element in a′grid, compute the correspoding c level
    for (i_a′, a′) in enumerate(a′grid)
        for s′ in 1:S
            Uc′[s′] = (cf[s′](a′)) ^ (-σ)
        end
        for s in 1:S
            c = (β * (1 + r̄) * (P[s, :]' * Uc′)) .^ (-1 / σ)
            n = get_n(w̄, A[s], c, σ, χ, γ)
            a = (a′ + c - A[s] * w̄ * n) / (1 + r̄)
            a_grid[s, i_a′ + n_con] = a
            c_grid[s, i_a′ + n_con] = c
        end
    end
    for s in 1:S
        if a_grid[s, 1 + n_con] > a_min
            for (i_ĉ, ĉ) in enumerate(LinRange(c_min[s], c_grid[s, n_con + 1], n_con + 1)[1:n_con])
                n̂ = get_n(w̄, A[s], ĉ, σ, χ, γ)
                â = (a_min + ĉ - A[s] * w̄ * n̂) / (1 + r̄)
                a_grid[s, i_ĉ] = â
                c_grid[s, i_ĉ] = ĉ
            end
        else
            a_grid[s, 1:n_con] .= -Inf
            c_grid[s, 1:n_con] .= -Inf
        end
    end
    #Now interpolate
    cf′ = Array{Spline1D}(undef, S)
    for s in 1:S
        if c_grid[s, 1] == -Inf
            indx = findall(a_grid[s, :] .< a_min)[end]
            cf′[s] = Spline1D(a_grid[s, indx:end], c_grid[s, indx:end]; k = k_spline)
        #If the constraint binds, we need to use all the grid points
        else
            cf′[s] = Spline1D(a_grid[s, :], c_grid[s, :]; k = k_spline)
        end
    end
    return cf′
end



## Use a contraction mapping to find the converged consumption function
# Tolerance to be set a 1e-5
function solve_c(cf, a′grid::Vector, para::HAmodel, tol = 1e-5)
    @unpack S = para
    compute_cmin!(para)
    diff = 1.0
    cf′ = Array{Spline1D}(undef, S)
    diffs = zeros(S)
    while diff > tol
        cf′ = approximate_c(cf, a′grid, para)
        for s in 1:S
            diffs[s] = norm(cf′[s].(a′grid) - cf[s].(a′grid), Inf)
        end
        diff = maximum(diffs)
        cf = cf′
    end
    return cf
end



## Function that computes the fixed point for the consumption function
function get_cf(para)
    compute_cmin!(para)
    @unpack r̄, w̄, a_min, a_max, Na, S, A, k_spline = para
    ## Set more curvature when in the lower range of a′grid
    a′grid = construct_agrid(a_min,a_max,Na)
    N = length(a′grid)
    ## Initialize the consumption function
    a_mat = zeros(S, N)
    c_mat = zeros(S, N)
    cf = Array{Spline1D}(undef, S)
    for s in 1:S
        a_vec = collect(LinRange(a_min, a_max, N))
        a_mat[s, :] = a_vec
        for (i_a, a) in enumerate(a_vec)
            c_mat[s, i_a] = A[s] * w̄ + r̄ * a
        end
    end
    for s in 1:S
        cf[s] = Spline1D(a_mat[s, :], c_mat[s, :]; k = k_spline)
    end
    ## Solve for the fixed point of the consumption function
    oldk = para.k_spline
    para.k_spline   = 1
    cf = solve_c(cf, a′grid, para)
    para.k_spline   = oldk
    cf = solve_c(cf, a′grid, para)
    return cf
end



## plot the policy functions
function plot_policies(para)
    @unpack σ, γ, β, χ, r̄, w̄, P, A, S, a_min, a_max, k_spline, c_min, stat_path = para
    cf = get_cf(para)
    p_c = plot(grid = false, xlabel = "a", ylabel = "c", title = "consumption policy")
    for s in 1:S
        plot!(p_c, a -> cf[s](a), a_min, a_max, label = "")
    end
    p_n = plot(grid = false, xlabel = "a", ylabel = "n", title = "labor policy")
    for s in 1:S
        plot!(p_n, a -> get_n(w̄, A[s], cf[s](a), σ, χ, γ), a_min, a_max, label = "")
    end
    p_aprime = plot(grid = false, xlabel = "a", ylabel = "aprime", title = "aprime policy")
    for s in 1:S
        plot!(p_aprime, a -> (1 + r̄) * a + A[s] * w̄ * get_n(w̄, A[s], cf[s](a), σ, χ, γ) - cf[s](a),
              a_min, a_max, label = "")
    end
    savefig(p_c, "../figures/$(stat_path)/policies/c.pdf")
    savefig(p_n, "../figures/$(stat_path)/policies/n.pdf")
    savefig(p_aprime, "../figures/$(stat_path)/policies/aprime.pdf")
end




## Mapping from two-dimensional indexing to one-dimensional indexing
function dimtrans2to1(N::Int64, i::Int64, s::Int64)
    return (i + (s - 1) * (N + 2))
end



## Mapping from one-dimensional indexing to two-dimensional indexing
function dimtrans1to2(N::Int64, k::Int)
    i = mod(k, N + 2)
    s = div(k, N + 2) + 1
    if i == 0
        i = N + 2
        s = s - 1
    end
    return i, s
end



## Create bins for asset holding
function get_bins(a_min::Float64, a_max::Float64, N::Int64)
    increment = (a_max - a_min) / N
    bin_midpts = [a_min]
    append!(bin_midpts, [a_min + (increment / 2) + (i - 1) * increment for i in 1:N])
    push!(bin_midpts, a_max)
    return bin_midpts
end



## Construct the transition matrix for the states
function construct_H(para::HAmodel, cf)
    @unpack σ, γ, χ, r̄, w̄, P, A, S, N, a_min, a_max = para
    bin_midpts = get_bins(a_min, a_max, N)
    ϵn_grid = zeros((N + 2) * S)
    n_grid = zeros((N + 2) * S)
    a_grid = zeros((N + 2) * S)
    c_grid = zeros((N + 2) * S)

    Ivec = zeros(Int,(N + 2) * S * S * 2)
    Jvec = zeros(Int,(N + 2) * S * S * 2)
    Vvec = zeros((N + 2) * S * S * 2)
    nS = 1 #number of elements used

    for k in 1:(N + 2) * S
        #transition to i′ with prob ω
        #transition to i′ + 1 with prob 1 - ω
        i′ = 0
        ω = 0.
        #given i, s
        i, s = dimtrans1to2(N, k)
        a = bin_midpts[i]
        c = cf[s](a)
        n = get_n(w̄, A[s], c, σ, χ, γ)
        a′ = A[s] * w̄ * n + (1 + r̄) * a - c
        ϵn_grid[k] = n * A[s]
        n_grid[k] = n
        a_grid[k] = a
        c_grid[k] = c
        #check if a′ falls into the very first or very last bin
        if a′ <= a_min
            i′ = 1
            ω = 1.0
        #check if a′ falls into the very last bin
        elseif a′ >= bin_midpts[N + 2]
            i′ = N + 1
            ω = 0.0
        else
            i′ = findfirst(a′ .<= bin_midpts) - 1
            ## calculate ω
            ω = (bin_midpts[i′ + 1] - a′) /
                (bin_midpts[i′ + 1] - bin_midpts[i′])
        end
        #transition to i′ with prob ω
        #transition to i′ + 1 with prob 1-ω
        #transition to sprime ∈ {1, ..., S} with the fowlling probabilities
        for (iprime, prob) in zip([i′ i′ + 1], [ω 1 - ω])
            for sprime in 1:S
                k′ = dimtrans2to1(N, iprime, sprime)
                #H[k, k′] = prob * P[s, sprime]
                Ivec[nS] = k
                Jvec[nS] = k′
                Vvec[nS] = prob * P[s, sprime]
                nS += 1
            end
        end
    end

    H = sparse(Ivec, Jvec, Vvec, (N + 2) * S, (N + 2) * S)
    return H, ϵn_grid, n_grid, a_grid, c_grid
end



## Compute the stationary distribution from the transition matrix for the states
function stat_dist(para, k)
    tol = 1e-10
    #k as the KN ratio
    @unpack α, δ, S, N = para
    para.r̄ = α * k ^ (α - 1) - δ
    para.w̄ = (1 - α) * k ^ α
    cf = get_cf(para)
    H, ϵn_grid, n_grid, a_grid, c_grid = construct_H(para, cf)
    π = ones(S * (N + 2)) / (S * (N + 2))
    diff = 1.0
    while diff > tol
        π_new = (π' * H)'
        diff = norm(π_new - π, Inf)
        #println(diff)
        π = π_new
    end
    return π, ϵn_grid, n_grid, a_grid, c_grid
end



## Construct the residual function for calibrating χ and β
# Find the fixed points for:
# (1) capital to output ratio K2Y
# (2) labor supply
function stationary_resid(x, α, K2Y, n̄, K2EN, para)
    para.β, para.χ = x[1],exp(x[2])
    println(x)
    π, ϵn_grid, n_grid, a_grid, c_grid = stat_dist(para, K2EN)
    ϵn = dot(ϵn_grid, π)
    n = dot(n_grid, π)
    K2EN = dot(a_grid, π) / ϵn
    diff_K2Y = max(K2EN, 0.) ^ (1 - α) - K2Y
    diff_n̄ = n - n̄
    println("diff_K2Y = $diff_K2Y, diff_n̄ = $diff_n̄")
    return diff_K2Y, diff_n̄, π, K2EN, ϵn_grid, n_grid, a_grid, c_grid
end



## Calibrating for χ and β, targeting K2Y ratio and average working hours
function calibrate_stationary!(para)
    @unpack α, K2Y, n̄ = para
    K2EN = (K2Y) ^ (1 / (1 - α))
    res = nlsolve(x -> stationary_resid(x, α, K2Y, n̄, K2EN, para)[1:2], [para.β; log(para.χ)]; inplace = false)
    para.β, para.χ = res.zero[1],exp(res.zero[2])
    diff_K2Y, diff_n̄, π, K2EN, ϵn_grid, n_grid, a_grid, c_grid = stationary_resid([para.β, log(para.χ)], α, K2Y, n̄, K2EN, para)
    para.ā = dot(π, a_grid)
    return para, π, K2EN, ϵn_grid, n_grid, a_grid, c_grid
end



## Plot the wealth distribution over a, make sure there is no bunching at a_max
function save_wealth_dist(para, π)
    @unpack a_min, a_max, N, stat_path = para
    agrid = collect(get_bins(a_min, a_max, N))
    πgrid = zeros(length(agrid))
    for k in 1:length(π)
        i, s = dimtrans1to2(N, k)
        πgrid[i] = πgrid[i] + π[k]
    end
    p1 = scatter(agrid[1:5], πgrid[1:5], label = "a", grid = false, title = "wealth distribtion for a in ($(agrid[1]), $(round(agrid[5]))")
    p2 = scatter(agrid[6:end], πgrid[6:end], label = "a", title = "wealth distribution from a = $(agrid[6])", grid = false)
    p3 = scatter(agrid[1:end], πgrid[1:end], label = "a", title = "wealth distribution", grid = false)
    writedlm("../data/$(stat_path)/over_a/a.csv", agrid, ',')
    writedlm("../data/$(stat_path)/over_a/pi.csv", πgrid, ',')
    savefig(p1, "../figures/$(stat_path)/over_a/wealth_low.pdf")
    savefig(p2, "../figures/$(stat_path)/over_a/wealth_high.pdf")
    savefig(p3, "../figures/$(stat_path)/over_a/wealth.pdf")
end



#=
## Check learning with constant beliefs set at HA rational
filenames = ["pi", "en", "n", "a"]
for yearly in [true; false]
    for iid in [true; false]
        println("yearly: $(yearly), iid: $(iid)")
        para = HAmodel(yearly = yearly, iid = iid)
        para, π, k, ϵn_grid, n_grid, a_grid, c_grid = calibrate_stationary!(para)
        println("β: $(para.β), χ: $(para.χ)")
        # Save calibrated β and χ
        writedlm("../data/$(para.stat_path)/calibration/beta.csv", para.β, ',')
        writedlm("../data/$(para.stat_path)/calibration/chi.csv", para.χ, ',')
        # Save two dimensional data over a and s
        data = π, ϵn_grid, n_grid, a_grid
        for (i, filename) in enumerate(filenames)
            writedlm("../data/$(para.stat_path)/over_a_s/$(filename).csv", data[i], ',')
        end
        # Save one dimensional data over a
        save_wealth_dist(para, π)
        # Plot the policy rules for c, n and aprime
        plot_policies(para)
    end
end



for yearly in [true; false]
    for iid in [true; false]
        println("yearly: $(yearly), iid: $(iid)")
        para = HAmodel(yearly = yearly, iid = iid)
        para, π, k, ϵn_grid, n_grid, a_grid, c_grid = calibrate_stationary!(para)
        println("β: $(para.β), χ: $(para.χ)")
    end
end
=#
