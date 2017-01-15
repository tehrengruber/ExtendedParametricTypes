module ExtendedParametricTypes

export @EPT

const field_type_generators = Dict{DataType, Function}()

# extract type_name, parametric_types, parametric_types_expr from an expression
#  for an expression like `:(Blub{A <: AbstractArray})` returns
#  (:Blub, [:A], [:(A <: AbstractArray)])
function extract_type_information(expr)
  @assert expr.head == :curly
  type_name = expr.args[1]
  parametric_types_expr = expr.args[2:end]
  parametric_types = map(pt -> begin
      if typeof(pt) <: Expr
        @assert pt.head == :<:
        pt.args[1]
      else
        pt
      end
    end,
    expr.args[2:end])

  type_name, parametric_types_expr, parametric_types
end

macro EPT(expr)
  # check that expression is a type declaration of not its an expansion
  if expr.head != :type
    additional_parametric_types_expr = :(ExtendedParametricTypes.field_type_generators[$(expr.args[1])]($(expr.args[2:end]...))...)
    push!(expr.args, additional_parametric_types_expr.args[1])
    return esc(expr)
    #error("Expected type declaration got $(args.head) expression")
  end
  # check that the type declaration has parametric types
  if !(typeof(expr.args[2]) <: Expr)
    error("Type declaration did not contain any parametric types")
  end
  # extract some information out of the expression
  does_inherit, supertype_expr = let
    if expr.args[2].head == :<:
      true, expr.args[2].args[2]
    elseif expr.args[2].head == :curly
      false, nothing
    else
      error("Structure of type declaration not known")
    end
  end
  type_name, parametric_types_expr, parametric_types = does_inherit ? extract_type_information(expr.args[2].args[1]) : extract_type_information(expr.args[2])
  decl_block = expr.args[3]
  # initialize dictionary storing the type generators
  field_type_generator_exprs = Array{Expr, 1}()
  # an array of additional parametric types to be used for
  #  fields with generated types
  additional_parametric_types = []
  # the actual field declarations used by the emmited type decl
  generated_field_decls = []
  # assembly type generators for all parametric types of the supertype_expr
  if does_inherit
    # only parametric types of the supertype may be generated
    if typeof(supertype_expr) <: Expr && supertype_expr.head == :curly
      supertype_name = supertype_expr.args[1]
      generated_supertype_expr = :($(supertype_name){})
      for (i, supertype_parametric_type_expr) in enumerate(supertype_expr.args[2:end])
        if is_generated_type_expr(supertype_parametric_type_expr, parametric_types)
          push!(field_type_generator_exprs, supertype_parametric_type_expr)
          push!(additional_parametric_types, Symbol("__SUPER_PT_$(i)"))
          push!(generated_supertype_expr.args, Symbol("__SUPER_PT_$(i)"))
        else
          push!(generated_supertype_expr.args, supertype_parametric_type_expr)
        end
      end
      supertype_expr = generated_supertype_expr
    end
  end
  # assemble type generators for all fields
  for field_decl in decl_block.args
    field_name = typeof(field_decl) <: Expr ? field_decl.args[1] : field_decl
    field_type_expr = typeof(field_decl) <: Expr ? field_decl.args[2] : Any
    # we only treat field declarations specially in which a parametric type
    #  occurs in a non-trivial way
    if typeof(field_decl) <: Expr && field_decl.head == :(::) && is_generated_field_expr(field_decl, parametric_types)
      # assemble field type generator
      #field_gen_expr = :(() -> $(field_type_expr))
      #field_gen_expr.args[1].args = parametric_types
      additional_parametric_type = Symbol("__" * uppercase(string(field_name)) * "_T")

      push!(field_type_generator_exprs, field_type_expr)
      push!(additional_parametric_types, additional_parametric_type)
      push!(generated_field_decls, :($(field_name)::$(additional_parametric_type)))
    else
      push!(generated_field_decls, field_decl)
    end
  end
  # assemble field type generator
  # TODO: since we also generate parametric types of the supertype this should be
  #  renamed
  field_type_generator = let e=:(function ()
      if length(_invalid_arguments) > 0
        error("too many parameters for extended parametric type $(type_name)")
      end
      # if all arguments are typevars we will just add typevars for all
      #  additional parametric types. This is used in cases where we dispatch
      #  on an EPT. If we have for example an EPT like this:
      #  ```
      #    @EPT type Bla{A}
      #     field::eltype(A)
      #    end
      #  ```
      #  then a function like `func{A}(::@EPT{Bla{A}})` becomes
      #  `func{A, _1}(::Bla{A, _1})`. Note that the TypeVar(:_1) is actually
      #  TypeVar(Symbol(":_A")) to avoid name clashes.
      # TODO: add tests for this
      if all(x -> typeof(x) <: TypeVar, ($(parametric_types...),))
        error("EPTs don't work with TypeVars yet.")
        #(map(x -> TypeVar(Symbol(":_" * string(x))), 1:$(length(field_type_generator_exprs)))...)
      else
        ($(field_type_generator_exprs...),)
      end
    end)
    e.args[1].args = copy(parametric_types) # add arguments to the generator expression
    push!(e.args[1].args, first(:(_invalid_arguments...).args))
    #macroexpand(:(@Base.pure $(e)))
    e
  end
  #println(field_type_generator)

  # todo: use concrete types here instead of the names of the parametric types
  display_string = "@EPT($(type_name){$(join(parametric_types_expr, ", "))))"

  # assemble the type declaration
  generated_type_decl = if does_inherit
    :(type $(type_name){$(parametric_types_expr...), $(additional_parametric_types...)} <: $(supertype_expr)
      $(generated_field_decls...)
    end)
  else
    :(type $(type_name){$(parametric_types_expr...), $(additional_parametric_types...)}
      $(generated_field_decls...)
    end)
  end
  expr = (esc(quote
    $(generated_type_decl)

    # evaluate field type generator expression
    #  we do this here since we want it to be in the right scope
    ExtendedParametricTypes.field_type_generators[$(type_name)] = $(field_type_generator)

    # add pretty printer
    import Base.show
    function show{$(parametric_types_expr...), $(additional_parametric_types...)}(io::IO, ::Type{$(type_name){$(parametric_types...), $(additional_parametric_types...)}})
      write(io, $(display_string))
    end
  end))
  expr
end

"""
does a parametric type occur in a non-trival way in the current field declaration

Examples:

- `is_generated_field_expr(:(field_name::A), [:A])` ⇔ false
   Parametric type `A` occurs in a trivial way
- `is_generated_field_expr(:(field_name::eltype(A)), [:A])` ⇔ true
   Parametric type `A` occurs in a non-trivial way
- `is_generated_field_expr(:(field_name::eltype(B)), [:A])` ⇔ false
   Paramatric type `A` does not occur at all
"""
function is_generated_field_expr(field_decl::Expr, parametric_types::Array)
  if typeof(field_decl.args[2]) <: Expr
    mapreduce(pt -> does_type_occur(pt, field_decl.args[2]), |, parametric_types)
  else
    false # occurence is either trivial or no occurence at all
  end
end

"""
does a parametric type occur in the given subtype expr

Examples:

- `is_generated_subtype_expr(:(A), [:A])` ⇔ false
   Parametric type `A` occurs in a trivial way
- `is_generated_subtype_expr(:(eltype(A)), [:A])` ⇔ true
   Parametric type `A` occurs in a non-trivial way
- `is_generated_subtype_expr(:(MyType{eltype(A)}), [:A])` ⇔ true
   Parametric type `A` occurs in a non-trivial way
- `is_generated_subtype_expr(:(MyType{A}), [:B])` ⇔ false
   Paramatric type `A` does not occur at all
"""
function is_generated_type_expr(type_expr::Union{Symbol, Expr}, parametric_types::Array)
  if typeof(type_expr) <: Expr
    mapreduce(expr -> mapreduce(pt -> does_type_occur(pt, expr, type_expr.head != :call), |, parametric_types),
              |, type_expr.args)
  else
    false # occurence is either trivial or no occurence at all
  end
end

function does_type_occur(searched_type::Symbol, expr::Expr, trivial=true)
  if expr.head == :call
    trivial = false
  end
  mapreduce(x -> does_type_occur(searched_type, x, trivial), |, expr.args)
end

does_type_occur(searched_type::Symbol, expr::Symbol, trivial=true) = !trivial && searched_type == expr

does_type_occur(searched_type::Symbol, expr, trivial=nothing) = false

end # module
