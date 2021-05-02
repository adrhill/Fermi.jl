using TensorOperations
using LinearAlgebra
using Fermi.DIIS
using Fermi.Integrals: projector
import Base: show

export RHF

abstract type RHFAlgorithm end

function get_scf_alg()
    implemented = [RHFa()]
    N = Options.get("scf_alg")
    try 
        return implemented[N]
    catch BoundsError
        throw(InvalidFermiOption("implementation number $N not available for RHF."))
    end
end

"""
    Fermi.HartreeFock.RHF

Wave function object for Restricted Hartree-Fock methods

# High Level Interface 
```
julia> @energy rhf
# Equivalent to
julia> Fermi.HartreeFock.RHF()
```
Computes RHF using information from Fermi.CurrentOptions.

# Fields:

    molecule    Molecule object used to compute the RHF wave function
    energy      RHF Energy
    ndocc       Number of doubly occupied spatial orbitals
    nvir        Number of virtual spatial orbitals
    orbitals    RHF Orbitals

# Relevant options 

These options can be set with `@set <option> <value>`

| Option         | What it does                      | Type      | choices [default]     |
|----------------|-----------------------------------|-----------|-----------------------|
| `scf_alg`      | Picks SCF algorithm               | `String`  | [conventional]        |
| `scf_max_rms`  | RMS density convergence criterion | `Float64` | [10^-9]               |
| `scf_max_iter` | Max number of iterations          | `Int`     | [50]                  |
| `scf_e_conv`   | Energy convergence criterion      | `Float64` | [10^-10]              |
| `basis`        | What basis set to use             | `String`  | ["sto-3g"]            |
| `df`           | Whether to use density fitting    | Bool      | false                 |
| `jkfit`        | What aux. basis set to use for JK | `String`  | ["auto"]              |
| `oda`          | Whether to use ODA                | `Bool`    | [`true`]              |
| `oda_cutoff`   | When to turn ODA off (RMS)        | `Float64` | [1E-1]                |
| `oda_shutoff`  | When to turn ODA off (iter)       | `Int`     | [20]                  |
| `scf_guess`    | Which guess density to use        | `String`  | "core" ["gwh"]        |

# Lower level interfaces

    RHF(molecule::Molecule, aoint::IntegralHelper, C::Array{Float64,2}, ERI::Array{Float64,N}, Λ::Array{Float64,2}) where N

The RHF kernel. Computes RHF on the given `molecule` with integral information defined in `aoint`. Starts from
the given C matrix as orbitals coefficients. Λ is the orthogonalizer (S^-1/2).

_struct tree:_

**RHF** <: AbstractHFWavefunction <: AbstractWavefunction
"""
struct RHF <: AbstractHFWavefunction
    molecule::Molecule
    energy::Float64
    ndocc::Int
    nvir::Int
    orbitals::RHFOrbitals
    converged::Bool
end

# Pretty printing
function string_repr(X::RHF)
    out = ""
    out = out*" ⇒ Fermi Restricted Hartree--Fock Wave function\n"
    out = out*" ⋅ Basis:                  $(X.orbitals.basis)\n"
    out = out*" ⋅ Energy:                 $(X.energy)\n"
    out = out*" ⋅ Occ. Spatial Orbitals: $(X.ndocc)\n"
    out = out*" ⋅ Vir. Spatial Orbitals: $(X.nvir)"
    return out
end

function show(io::IO, ::MIME"text/plain", X::RHF)
    print(string_repr(X))
end

function RHF(x...)
    if !any(i-> i isa RHFAlgorithm, x)
        RHF(x..., get_scf_alg())
    else
        throw(MethodArgument("invalid arguments for RHF method: $(x[1:end-1])"))
    end
end

# Actual HF routine is in here
include("AuxRHF.jl")
# For each implementation a singleton type must be create
struct RHFa <: RHFAlgorithm end
include("RHFa.jl")