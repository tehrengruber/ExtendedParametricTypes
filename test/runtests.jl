module WTF

using ExtendedParametricTypes
using Base.Test

ExtendedParametricTypes.@Initialize

@EPT type Bla{A}
  field::eltype(A)
end

# test that the type of the `field` field is an Int for @EPT(Bla{Array{Int, 1}}
@test fieldtype(@EPT(Bla{Array{Int, 1}}), :field) == Int

# test non-type stable EPT expansion
T = Bla
@test fieldtype(@EPT(T{Array{Int, 1}}), :field) == Int

# test type stable EPT expansion
dummy = () -> @EPT(Bla{Array{Int, 1}})(1)
@inferred dummy()

let instance = @EPT(Bla{Array{Int, 1}})(3)
  @test instance.field == 3
end

abstract AbstractBlab{A, B}

@EPT type Blub{A <: AbstractArray} <: AbstractBlab{eltype(A), Int}
  field::eltype(A)
end

let instance = @EPT(Blub{Array{Int, 1}})(3)
  @test instance.field == 3
end

@EPT type Blab{A <: AbstractArray}
  field::Array{eltype(A), 1}
end

# nested EPT's
@EPT type BlaBlub{T}
  field::@EPT(Bla{Array{T, 1}})
end

@test fieldtype(@EPT(BlaBlub{Int}), :field) == @EPT(Bla{Array{Int, 1}})

end
