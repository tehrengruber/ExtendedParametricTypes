# ExtendedParametricTypes

This module allows deferring the calculation of field types until type parameters are known (see https://github.com/JuliaLang/julia/issues/18466).

__Example__

```julia
using ExtendedParametricTypes

# must be called once in every module it is being used in
ExtendedParametricTypes.@Initialize

@EPT type Bla{A}
  field::eltype(A)
end

obj = @EPT(Bla{Array{Int, 1}})(3)

# evaluates to true
fieldtype(@EPT(Bla{Array{Int, 1}}), :field) == Int

# return type of this anonymous function is inferred correctly to Int
dummy = () -> @EPT(Bla{Array{Int, 1}})(1).field
assert(first(Base.return_types(dummy)) == Int)
```

Prototype. Expect things to break.

## TODO

- Dispatch on EPTs does not work
- Add some error handling
