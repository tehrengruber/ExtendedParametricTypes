module ExtendedParametricTypes

export @EPT

const parametric_type_generator_map = Dict{DataType, Array{Function, 1}}()

macro Initialize()
  esc(quote
    # this macro is evaluted in the scope of the module it is beeing used in.
    # we do this to be able to run eval inside of the scope of that module.
    # note that eval is not used to evaluate any code of the expression passed to
    # the EPT macro! we only need it to access the types of the module in order
    # to generate type stable code.
    macro EPT(expr)
      # get some variables that live in the ExtendedParametricTypes module
      extract_type_information = ExtendedParametricTypes.extract_type_information
      is_generated_field_expr = ExtendedParametricTypes.is_generated_field_expr
      is_generated_type_expr = ExtendedParametricTypes.is_generated_type_expr
      does_type_occur = ExtendedParametricTypes.does_type_occur
      parametric_type_generator_map = ExtendedParametricTypes.parametric_type_generator_map

      # if the expression is not a type decleration it
      if expr.head == :curly
        expanded_expr = try
          try
            # make a shallow copy of the expression. in case this try block
            #  fails the catch block will still work on the unmodifed expr
            expr_copy = copy(expr)
            # we compile a function that just returns the unparameterized type
            helper_func = eval(:(() -> $(expr_copy.args[1])))
            # if we can infer the return type of that function (does not work
            #  from generated functions) and it is not an abstract type
            #  we are able to get the needed generators
            unparameterized_type = first(first(Base.return_types(helper_func)).parameters)
            unparameterized_type.abstract && throw("")
            core_args = copy(expr_copy.args[2:end])
            for parametric_type_generator in parametric_type_generator_map[unparameterized_type]
              additional_parametric_types_expr = :($(parametric_type_generator)($(core_args...)))
              push!(expr_copy.args, additional_parametric_types_expr)
            end
            expr_copy
          catch e
            # if an exception was thrown the generator is feteched after the
            #  macro was expanded. this however prevents type inference, so whenever
            #  you can you should avoid that this happens.
            warn("Could not determine extended parametric type on macro expansion. A type unstable version is used instead.")
            expr = :(let generators = ExtendedParametricTypes.parametric_type_generator_map[$(expr.args[1])]
              expanded_additional_parametric_types = Array{DataType, 1}()
              for generator in generators
                push!(expanded_additional_parametric_types, generator($(expr.args[2:end]...)))
              end
              $(expr.args[1]){$(expr.args[2:end]...), expanded_additional_parametric_types...}
            end)
            expr
          end
        catch e
          info("Exception was thrown during EPT expansion. Please submit a bug report.")
          rethrow(e)
        end
        #println(esc(expanded_expr))
        return esc(expanded_expr)
      end

      assert(expr.head == :type)

      # the fields may contain other EPTs so we need to expand them to
      #  determine correctly whether the parametric types occur no trivially
      expr = macroexpand(expr)

      # check that the type declaration has parametric types
      if !(typeof(expr.args[2]) <: Expr)
        error("EPT declaration did not contain any parametric types")
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
      type_name, parametric_types_expr, parametric_types = does_inherit ?
        extract_type_information(expr.args[2].args[1]) : extract_type_information(expr.args[2])
      decl_block = expr.args[3]
      # initialize array storing the expression of all type generators for this type
      parametric_type_generator_exprs = Array{Expr, 1}()
      # an array of additional parametric types
      additional_parametric_types = []
      # assembly type generators for all parametric types of the supertype expr
      if does_inherit
        # only parametric types of the supertype may be generated
        if typeof(supertype_expr) <: Expr && supertype_expr.head == :curly
          supertype_name = supertype_expr.args[1]
          generated_supertype_expr = :($(supertype_name){})
          for (i, supertype_parametric_type_expr) in enumerate(supertype_expr.args[2:end])
            if is_generated_type_expr(supertype_parametric_type_expr, parametric_types)
              push!(parametric_type_generator_exprs, supertype_parametric_type_expr)
              push!(additional_parametric_types, Symbol("__SUPER_PT_$(i)"))
              push!(generated_supertype_expr.args, Symbol("__SUPER_PT_$(i)"))
            else
              push!(generated_supertype_expr.args, supertype_parametric_type_expr)
            end
          end
          supertype_expr = generated_supertype_expr
        end
      end

      # the actual field declarations used by the emmited type decl
      generated_field_decls = []
      # assemble type generators for all fields
      for field_decl in decl_block.args
        field_name = typeof(field_decl) <: Expr ? field_decl.args[1] : field_decl
        field_type_expr = typeof(field_decl) <: Expr ? field_decl.args[2] : Any
        # we only treat field declarations specially in which a parametric type
        #  occurs in a non-trivial way
        if typeof(field_decl) <: Expr && field_decl.head == :(::) && is_generated_field_expr(field_decl, parametric_types)
          # assemble field type generator
          additional_parametric_type = Symbol("__" * uppercase(string(field_name)) * "_T")

          push!(parametric_type_generator_exprs, field_type_expr)
          push!(additional_parametric_types, additional_parametric_type)
          push!(generated_field_decls, :($(field_name)::$(additional_parametric_type)))
        else
          push!(generated_field_decls, field_decl)
        end
      end

      #
      # assemble field type generators
      #
      add_generators_expr = Expr(:block)
      for expr in parametric_type_generator_exprs
        generator = :(function ()
            if all(x -> typeof(x) <: TypeVar, ($(parametric_types...),))
              error("EPTs don't work with TypeVars yet.")
            end
          $(expr)
        end)
        generator = macroexpand(:(@Base.pure $(generator)))
        generator.args[1].args = copy(parametric_types)
        push!(add_generators_expr.args, :(push!(generators, $(generator))))
      end

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
        ExtendedParametricTypes.parametric_type_generator_map[$(type_name)] = let generators = Function[]
          $(add_generators_expr)
          generators
        end

        # add pretty printer
        import Base.show
        function show{$(parametric_types_expr...), $(additional_parametric_types...)}(io::IO, ::Type{$(type_name){$(parametric_types...), $(additional_parametric_types...)}})
          write(io, $(display_string))
        end
      end))
      #println(expr)
      expr
    end
  end)
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

end # module
