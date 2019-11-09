#=
Find toplevel items (bind / call)

- downstreams: modules.jl, outline.jl, goto.jl
=#


abstract type ToplevelItem end

struct ToplevelBinding <: ToplevelItem
    expr::CSTParser.EXPR
    bind::CSTParser.Binding
    lines::UnitRange{Int}
end

struct ToplevelCall <: ToplevelItem
    expr::CSTParser.EXPR
    lines::UnitRange{Int}
    callstr::String
end

struct ToplevelTupleH <: ToplevelItem
    expr::CSTParser.EXPR
    lines::UnitRange{Int}
end

"""
    toplevelitems(text::String; kwargs...)::Vector{ToplevelItem}
    toplevelitems(text::String, expr::CSTParser.EXPR; kwargs...)::Vector{ToplevelItem}

Finds and returns toplevel "item"s (call and binding) in `text`.

keyword arguments:
- `mod::Union{Nothing, String}`: if not `nothing` don't return items within modules
    other than `mod`, otherwise enter into every module.
- `inmod::Bool`: if `true`, don't include toplevel items until it enters into `mod`.
"""
toplevelitems(text::String; kwargs...) = _toplevelitems(text, CSTParser.parse(text, true); kwargs...)
toplevelitems(text::String, expr::CSTParser.EXPR; kwargs...) = _toplevelitems(text, expr; kwargs...)
toplevelitems(text::String, expr::Nothing; kwargs...) = ToplevelItem[]

function _toplevelitems(
    text::String, expr::CSTParser.EXPR,
    items::Vector{ToplevelItem} = ToplevelItem[], line::Int = 1, pos::Int = 1;
    mod::Union{Nothing, String} = nothing, inmod::Bool = false,
)
    shouldadd = mod === nothing || inmod

    # binding
    bind = CSTParser.bindingof(expr)
    if bind !== nothing && shouldadd
        lines = line:line+countlines(expr, text, pos, false)
        push!(items, ToplevelBinding(expr, bind, lines))
    end

    lines = line:line+countlines(expr, text, pos, false)

    # toplevel call
    if iscallexpr(expr) && shouldadd
        push!(items, ToplevelCall(expr, lines, str_value_as_is(expr, text, pos)))
    end

    # destructure multiple returns
    if ismultiplereturn(expr) && shouldadd
        push!(items, ToplevelTupleH(expr, lines))
    end

    # look for more toplevel items in expr:
    if shouldenter(expr, mod)
        if expr.args !== nothing
            if ismodule(expr) && shouldentermodule(expr, mod)
                inmod = true
            end
            for arg in expr.args
                _toplevelitems(text, arg, items, line, pos; mod = mod, inmod = inmod)
                line += countlines(arg, text, pos)
                pos += arg.fullspan
            end
        end
    end
    return items
end

function shouldenter(expr::CSTParser.EXPR, mod::Union{Nothing, String})
    !(scopeof(expr) !== nothing && !(
        expr.typ === CSTParser.FileH ||
        (ismodule(expr) && shouldentermodule(expr, mod)) ||
        isdoc(expr)
    ))
end

shouldentermodule(expr::CSTParser.EXPR, mod::Nothing) = true
shouldentermodule(expr::CSTParser.EXPR, mod::String) = expr.binding.name == mod
