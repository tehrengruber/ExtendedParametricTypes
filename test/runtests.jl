using ExtendedParametricTypes
using Base.Test

@EPT type Bla{A}
  field::eltype(A)
end

@test fieldtype(@EPT(Bla{Array{Int, 1}}), :field) == Int

let instance = @EPT(Bla{Array{Int, 1}})(3)
  @test instance.field == 3
  println(instance)
end

abstract AbstractBlab{A, B}

@EPT type Blub{A <: AbstractArray} <: AbstractBlab{eltype(A), Int}
  field::eltype(A)
end

println(macroexpand(:(@EPT(Blub{Array{Int, 1}}))))

c = () -> @EPT(Blub{Array{Int, 1}})(3)
println(@code_warntype c())

let instance = @EPT(Blub{Array{Int, 1}})(3)
  @test instance.field == 3
end

@EPT type Blab{A <: AbstractArray}
  field::Array{eltype(A), 1}
end
