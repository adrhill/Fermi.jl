"""
    Fermi.Integrals

Module to compute integrals using Lints.jl
"""
module Integrals

using Fermi
using Fermi.Error
using Fermi.Options
using Fermi.Geometry: Molecule
using LinearAlgebra
using TensorOperations

import Base: getindex, setindex!, delete!

export IntegralHelper
export delete!

include("Lints.jl")

abstract type AbstractIntegralHelper end

"""
    IntegralHelper{T}

Structure to assist with computing and storing integrals. 
Accesss like a dictionary e.g.,
    ints["S"]

A key is associated with each type of integral

    "S"           -> AO overlap integral
    "T"           -> AO electron kinetic energy integral
    "V"           -> AO electron-nuclei attraction integral
    "ERI"         -> AO electron repulsion integral
    "JKERI"       -> AO JK density fitted electron repulsion integral
    "RIERI"       -> AO RI density fitted electron repulsion integral

# Fields
    mol                         Associated Fermi Molecule object
    basis                       Basis set used within the helper
    aux                         Auxiliar basis set used in density fitting
    cache                       Holds integrals already computed 
    normalize                   Do normalize integrals? `true` or `false`
"""
struct IntegralHelper{T,E,O} <: AbstractIntegralHelper where {T<:AbstractFloat, E<:AbstractERI, O<:AbstractOrbitals}
    molecule::Molecule
    orbitals::O
    basis::String
    aux::String
    cache::Dict{String,FermiMDArray{T}} 
    eri_type::E
    normalize::Bool
end
function IntegralHelper(;molecule = Molecule(), orbitals = AtomicOrbitals(), 
                           basis = Options.get("basis"), aux = Options.get("jkfit") normalize = false)

    # Check if density-fitting is requested
    if Options.get("df")
        # If the associated orbitals are AtomicOrbitals and DF is requested, JKFIT is set by default
        # Otherwise, the ERI type will be RIFIT
        eri_type = orbitals === AtomicOrbitals() ? JKFIT() : RIFIT()
    else
        eri_type = Chonky()
    end

    # If aux is auto, determine the aux basis from the basis
    if aux == "auto"
        std_name = Regex("cc-pv.z")
        aux = occursin(std_name, basis) ? basis*"-jkfit" : "cc-pvqz-jkfit"
    end

    # Starts an empty cache

    precision = Options.get("precision")
    if precision == "single"
        cache = Dict{String, FermiMDArray{Float32}}() 
    elseif precision == "double"
        cache = Dict{String, FermiMDArray{Float64}}() 
    else
        throw(InvalidFermiOption("precision can only be `single` or `double`. Got $precision"))
    end

    # Return IntegralHelper object
    IntegralHelper{T}(molecule, orbitals, basis, aux, cache, eri_type, normalize=normalize)
end

# Clears cache and change normalize key
function normalize!(I::IntegralHelper,normalize::Bool)
    if I.normalize != normalize
        I.normalize = normalize
        for entry in keys(I.cache)
            delete!(I.cache, entry)
        end
    end
end

"""
    getindex(I::IntegralHelper,entry::String)

Called when `helper["foo"]` syntax is used. If the requested entry already
exists, simply return the entry. If not, compute the requested entry.
"""
function getindex(I::AbstractIntegralHelper,entry::String)
    if haskey(I.cache, entry)
        return I.cache[entry]
    else
        compute!(I, entry)
        return I.cache[entry]
    end
end

function setindex!(I::AbstractIntegralHelper, A::FermiMDArray, key::String)
    I.cache[key] = A
end

function delete!(I::AbstractIntegralHelper, keys...)
    for k in keys
        delete!(I.cache, k)
    end
    GC.gc()
end

function delete!(I::AbstractIntegralHelper)
    delete!(I, keys(I.cache)...)
end

function compute!(I::IntegralHelper{Float64}, entry::String)

    if entry == "S" #AO basis overlap
        I.cache["S"] = FermiMDArray(ao_overlap(I.mol, I.basis, normalize = I.normalize))

    elseif entry == "T" #AO basis kinetic
        I.cache["T"] = FermiMDArray(ao_kinetic(I.mol, I.basis, normalize = I.normalize))

    elseif entry == "V" #AO basis nuclear
        I.cache["V"] = FermiMDArray(ao_nuclear(I.mol, I.basis, normalize = I.normalize))

    elseif entry == "ERI" 
        I.cache["ERI"] = FermiMDArray(ao_eri(I.mol, I.basis, normalize = I.normalize))

    elseif entry == "JKERI"
        I.cache["JKERI"] = FermiMDArray(df_ao_eri(I.mol, I.basis, I.auxjk, normalize = I.normalize))

    elseif entry == "RIERI"
        I.cache["RIERI"] = FermiMDArray(df_ao_eri(I.mol, I.basis, I.auxri, normalize = I.normalize))

    else
        throw(Fermi.InvalidFermiOption("Invalid key for IntegralHelper: $(entry)."))
    end
end

function compute_S!(I::IntegralHelper{T, E, AtomicOrbitals}) where {T<:AbstractFloat, E<:AbstractERI}
        I.cache["S"] = FermiMDArray(ao_overlap(I.mol, I.basis, normalize = I.normalize))
end


function ao_to_mo!(aoints::IntegralHelper, O::AbstractRestrictedOrbitals, entries...; phys=false)

    moint = MOIntegralHelper(O, auxri=aoints.auxri, phys=phys)
    #delete!(aoints, "JKERI", "S", "T", "V")

    for entry in entries
        compute!(moint, entry, aoints)
    end
    delete!(aoints)
    return moint
end

function compute!(I::MOIntegralHelper{T,O}, entry::String, ints::IntegralHelper=IntegralHelper()) where {T <: AbstractFloat, O <: AbstractRestrictedOrbitals}

    core = Fermi.Options.get("drop_occ")
    inac = Fermi.Options.get("drop_vir")

    if core ≥ 2*I.αocc
        throw(InvalidFermiOption("too many core electrons ($core) for Ne = $(2*I.αocc)."))
    end

    if inac ≥ 2*I.αvir
        throw(InvalidFermiOption("too many inactive orbitals ($inac) for # virtuals = $(2*I.αvir)."))
    end
    o = (core+1):I.αocc
    v = (I.αocc+1):(I.αocc + I.αvir - inac)

    Co = I.orbitals.C[:,o]
    Cv = I.orbitals.C[:,v]

    chem = I.phys ? entry[[1,3,2,4]] : entry
    if chem == "OOOO"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            OOOO[i,j,k,l] :=  AOERI[μ, ν, ρ, σ]*Co[μ, i]*Co[ν, j]*Co[ρ, k]*Co[σ, l]
        end
        I.cache[entry] = I.phys ? permutedims(OOOO, (1,3,2,4)) : OOOO

    elseif chem == "OOOV"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            OOOV[i,j,k,a] :=  AOERI[μ, ν, ρ, σ]*Co[μ, i]*Co[ν, j]*Co[ρ, k]*Cv[σ, a]
        end
        I.cache[entry] = I.phys ? permutedims(OOOV, (1,3,2,4)) : OOOV

    elseif chem == "OVOV"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            OVOV[i,a,j,b] :=  AOERI[μ, ν, ρ, σ]*Co[μ, i]*Cv[ν, a]*Co[ρ, j]*Cv[σ, b]
        end
        I.cache[entry] = I.phys ? permutedims(OVOV, (1,3,2,4)) : OVOV

    elseif chem == "OOVV"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            OOVV[i,j,a,b] :=  AOERI[μ, ν, ρ, σ]*Co[μ, i]*Co[ν, j]*Cv[ρ, a]*Cv[σ, b]
        end
        I.cache[entry] = I.phys ? permutedims(OOVV, (1,3,2,4)) : OOVV

    elseif chem == "OVVV"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            OVVV[i,a,b,c] :=  AOERI[μ, ν, ρ, σ]*Co[μ, i]*Cv[ν, a]*Cv[ρ, b]*Cv[σ, c]
        end
        I.cache[entry] = I.phys ? permutedims(OVVV, (1,3,2,4)) : OVVV

    elseif chem == "VVVV"
        AOERI = ints["ERI"]
        @tensoropt (μ=>100, ν=>100, ρ=>100, σ=>100, i=>10, j=>10, k=>10, l=>10, a=>80, b=>80, c=>80, d=>80) begin 
            VVVV[a,b,c,d] :=  AOERI[μ, ν, ρ, σ]*Cv[μ, a]*Cv[ν, b]*Cv[ρ, c]*Cv[σ, d]
        end
        I.cache[entry] = I.phys ? permutedims(VVVV, (1,3,2,4)) : VVVV
    elseif chem == "BOV"
        AOERI = ints["RIERI"]
        @tensoropt (P => 100, μ => 50, ν => 50, i => 10, a => 40) begin 
            Bov[P,i,a] :=  AOERI[P,μ, ν]*Co[μ, i]*Cv[ν, a]
        end
        I.cache["BOV"] = Bov
    elseif chem == "BOO"
        AOERI = T.(ints["RIERI"])
        @tensoropt (P => 100, μ => 50, ν => 50, i => 10, a => 40) begin 
            Boo[P,i,a] :=  AOERI[P,μ, ν]*Co[μ, i]*Co[ν, a]
        end
        I.cache["BOO"] = Boo
    elseif chem == "BOV"
        AOERI = T.(ints["RIERI"])
        @tensoropt (P => 100, μ => 50, ν => 50, i => 10, a => 40) begin 
            Bvv[P,i,a] :=  AOERI[P,μ, ν]*Cv[μ, i]*Cv[ν, a]
        end
        I.cache["BVV"] = Bvv
    end
end

end #module
