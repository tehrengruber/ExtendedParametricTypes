# ExtendedParametricTypes

This module allows deferring the calculation of field types until type parameters are known (see https://github.com/JuliaLang/julia/issues/18466).

__Example__

```
using ExtendedParametricTypes
@EPT type Bla{A}
  field::eltype(A)
end

obj = @EPT(Bla{Array{Int, 1}})(3)

# evaluates to true
fieldtype(@EPT(Bla{Array{Int, 1}}), :field) == Int
```

Prototype. Expect things to break.
