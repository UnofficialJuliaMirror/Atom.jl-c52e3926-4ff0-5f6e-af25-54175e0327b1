using CSTParser

### toplevel bindings - outline, goto ###

# TODO?: create separate function to search toplevel bindings, and to search calls

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

function toplevelitems(expr, text, items::Vector{ToplevelItem} = Vector{ToplevelItem}(), line = 1, pos = 1)
    # binding
    bind = CSTParser.bindingof(expr)
    if bind !== nothing
        lines = line:line+countlines(expr, text, pos, false)
        push!(items, ToplevelBinding(expr, bind, lines))
    end

    lines = line:line+countlines(expr, text, pos, false)

    # toplevel call
    if iscallexpr(expr)
        push!(items, ToplevelCall(expr, lines, str_value_asis(expr, text, pos)))
    end

    # destructure multiple returns
    ismultiplereturn(expr) && push!(items, ToplevelTupleH(expr, lines))

    # look for more toplevel items in expr:
    if shouldenter(expr)
        if expr.args !== nothing
            for arg in expr.args
                toplevelitems(arg, text, items, line, pos)
                line += countlines(arg, text, pos)
                pos += arg.fullspan
            end
        end
    end
    return items
end

iscallexpr(expr::CSTParser.EXPR) = expr.typ === CSTParser.Call || expr.typ === CSTParser.MacroCall

function shouldenter(expr)
    !(scopeof(expr) !== nothing && !(
        expr.typ === CSTParser.FileH ||
        expr.typ === CSTParser.ModuleH ||
        expr.typ === CSTParser.BareModule ||
        isdoc(expr)
    ))
end

function isdoc(expr)
    expr.typ === CSTParser.MacroCall &&
        length(expr.args) >= 1 &&
        (
            expr.args[1].typ === CSTParser.GlobalRefDoc ||
            str_value(expr.args[1]) == "@doc"
        )
end

handle("outline") do text
    try
        outline(text)
    catch err
        []
    end
end

function outline(text)
    parsed = CSTParser.parse(text, true)
    items = toplevelitems(parsed, text)
    filter!(map(outlineitem, items)) do item
        item !== nothing
    end
end
function outlineitem(binding::ToplevelBinding)
    expr = binding.expr
    bind = binding.bind
    lines = binding.lines

    name = bind.name
    if CSTParser.has_sig(expr)
        name = str_value(CSTParser.get_sig(expr))
    end
    type = static_type(bind)
    icon = static_icon(bind)
    Dict(
        :name  => name,
        :type  => type,
        :icon  => icon,
        :lines => [first(lines), last(lines)]
    )
end
function outlineitem(call::ToplevelCall)
    expr = call.expr
    lines = call.lines

    # don't show doc strings
    isdoc(expr) && return nothing

    # show first line verbatim of macro calls
    if ismacrocall(expr)
        return Dict(
            :name  => strlimit(first(split(call.callstr, '\n')), 100),
            :type  => "snippet",
            :icon  => "icon-mention",
            :lines => [first(lines), last(lines)],
        )
    end

    # show includes
    if isinclude(expr)
        name = "include"
        return Dict(
            :name  => call.callstr,
            :type  => "module",
            :icon  => "icon-file-code",
            :lines => [first(lines), last(lines)],
        )
    end

    return nothing
end
function outlineitem(tupleh::ToplevelTupleH)
    expr = tupleh.expr
    lines = tupleh.lines

    # `expr.parent` is always `CSTParser.EXPR`
    type = isconst(expr.parent) ? "constant" : "variable"
    icon = isconst(expr.parent) ? "c" : "v"

    Dict(
        :name  => str_value(expr),
        :type  => type,
        :icon  => icon,
        :lines => [first(lines), last(lines)]
    )
end

ismacrocall(expr) = expr.typ === CSTParser.MacroCall

function isinclude(expr)
    expr.typ === CSTParser.Call &&
        length(expr.args) >= 3 &&
        expr.args[1].val == "include"
end

### local bindings -- completions, goto, datatip ###

struct LocalBinding
    name::String
    bindstr::String
    span::UnitRange{Int64}
    line::Int
    expr::CSTParser.EXPR
end

struct LocalScope
    name::String
    bindstr::String
    span::UnitRange{Int64}
    line::Int
    children::Vector{Union{LocalBinding, LocalScope}}
    expr::CSTParser.EXPR
end

function locals(text, line, col)
    parsed = CSTParser.parse(text, true)
    bindings = local_bindings(parsed, text)
    actual_local_bindings(bindings, line, byteoffset(text, line, col))
end

function local_bindings(expr, text, bindings = [], pos = 1, line = 1)
    # binding
    bind = CSTParser.bindingof(expr)
    scope = scopeof(expr)
    if bind !== nothing && scope === nothing
        bindstr = str_value_asis(bind, text, pos)
        range = pos:pos+expr.span
        push!(bindings, LocalBinding(bind.name, bindstr, range, line, expr))
    end

    if scope !== nothing
        expr.typ == CSTParser.Kw && return bindings

        if ismultiplereturn(expr)
            # destructure multiple returns
            if expr.args !== nothing
                for arg in expr.args
                    # don't update `pos` & `line`, i.e.: treat all the multiple returns at a same place
                    local_bindings(arg, text, bindings, pos, line)
                end
            end
        else
            # find local binds in a scope
            # calculate fields for `LocalScope` first
            bindstr = str_value_asis(expr, text, pos)
            range = pos:pos+expr.span
            name = bind === nothing ? "" : bind.name

            localbindings = []
            if expr.args !== nothing
                for arg in expr.args
                    local_bindings(arg, text, localbindings, pos, line)
                    line += countlines(arg, text, pos)
                    pos += arg.fullspan
                end
            end

            push!(bindings, LocalScope(name, bindstr, range, line, localbindings, expr))
        end

        return bindings
    end

    # look for more local bindings if exists
    if expr.args !== nothing
        for arg in expr.args
            local_bindings(arg, text, bindings, pos, line)
            line += countlines(arg, text, pos)
            pos += arg.fullspan
        end
    end

    return bindings
end

function byteoffset(text, line, col)
    byteoffset = 1
    current_line = 1
    current_char = 0
    for c in text
        if line == current_line
            current_char += 1
            c === '\n' && break
        end
        current_char == col && break
        byteoffset += VERSION >= v"1.1" ? ncodeunits(c) : ncodeunits(string(c))
        c === '\n' && (current_line += 1)
    end
    byteoffset
end

function actual_local_bindings(bindings, line, byteoffset, root = "", actual_bindings = [])
    for bind in bindings
        push!(actual_bindings, Dict(
            :name     => bind.name,
            :bindstr  => bind.bindstr,
            :root     => root,
            :line     => bind.line,
            :locality => distance(line, byteoffset, bind.line, bind.span),
            :icon     => static_icon(bind.expr),
            :type     => static_type(bind.expr),
        ))
        if bind isa LocalScope && byteoffset in bind.span
            actual_local_bindings(bind.children, line, byteoffset, bind.name, actual_bindings)
        end
    end

    filter!(b -> !isempty(b[:name]), actual_bindings)
    sort!(actual_bindings, lt = (b1, b2) -> b1[:locality] < b2[:locality])
    unique(b -> b[:name], actual_bindings)
end

function distance(line, byteoffset, defline, defspan)
    abslinediff = abs(line - defline)
    absbytediff = abs(byteoffset - defspan[1]) # tiebreaker for bindings on the same line
    diff = if byteoffset in defspan
        Inf
    elseif line < defline
        (defline - line)*10 # bindings defined *after* the current line have a lower priority
    else
        line - defline
    end
    diff + absbytediff*1e-6
end

### utils ###

function scopeof(expr)
    scope = CSTParser.scopeof(expr)
    if scope ≠ nothing
        return scope
    else
        # can remove this with CSTParser 0.6.3
        if expr.typ == CSTParser.BinaryOpCall && expr.args[2].kind == CSTParser.Tokens.ANON_FUNC
            return :anon
        end

        if expr.typ == CSTParser.Call && expr.parent ≠ nothing && scopeof(expr.parent) == nothing
            return :call
        end

        if expr.typ == CSTParser.MacroCall
            return :macro
        end

        if expr.typ == CSTParser.TupleH && expr.parent ≠ nothing && scopeof(expr.parent) == nothing
            return :tupleh
        end
    end
    return nothing
end

function Base.countlines(expr::CSTParser.EXPR, text::String, pos::Int, full::Bool = true; eol = '\n')
    endpos = pos + (full ? expr.fullspan : expr.span)
    n = ncodeunits(text)
    s = nextind(text, clamp(pos - 1, 0, n))
    e = prevind(text, clamp(endpos, 1, n + 1))
    count(c -> c === eol, text[s:e])
end

function ismultiplereturn(expr)
    expr.typ === CSTParser.TupleH &&
    !isempty(filter(a -> CSTParser.bindingof(a) !== nothing, expr.args))
end

# adapted from https://github.com/julia-vscode/DocumentFormat.jl/blob/b7e22ca47254007b5e7dd3c678ba27d8744d1b1f/src/passes.jl#L108
function str_value(x)
    if x.typ === CSTParser.PUNCTUATION
        x.kind == CSTParser.Tokens.LPAREN && return "("
        x.kind == CSTParser.Tokens.LBRACE && return "{"
        x.kind == CSTParser.Tokens.LSQUARE && return "["
        x.kind == CSTParser.Tokens.RPAREN && return ")"
        x.kind == CSTParser.Tokens.RBRACE && return "}"
        x.kind == CSTParser.Tokens.RSQUARE && return "]"
        x.kind == CSTParser.Tokens.COMMA && return ", "
        x.kind == CSTParser.Tokens.SEMICOLON && return ";"
        x.kind == CSTParser.Tokens.AT_SIGN && return "@"
        x.kind == CSTParser.Tokens.DOT && return "."
        return ""
    elseif x.kind === CSTParser.Tokens.TRIPLE_STRING
        return string("\"\"\"", x.val, "\"\"\"")
    elseif x.kind === CSTParser.Tokens.STRING
        return string("\"", x.val, "\"")
    elseif x.kind === CSTParser.Tokens.EQ
        return " = "
    elseif x.kind === CSTParser.Tokens.WHERE
        return " where "
    elseif x.typ === CSTParser.Parameters
        return "; " * join(str_value(a) for a in x)
    elseif x.typ === CSTParser.IDENTIFIER || x.typ === CSTParser.LITERAL || x.typ === CSTParser.OPERATOR || x.typ === CSTParser.KEYWORD
        return CSTParser.str_value(x)
    else
        return join(str_value(a) for a in x)
    end
end

function str_value_asis(expr::CSTParser.EXPR, text::String, pos::Int)
    endpos = pos + expr.span
    n = ncodeunits(text)
    s = nextind(text, clamp(pos - 1, 0, n))
    e = prevind(text, clamp(endpos, 1, n + 1))
    strip(text[s:e])
end
str_value_asis(bind::CSTParser.Binding, text::String, pos::Int) = str_value_asis(bind.val, text, pos)
str_value_asis(bind, text::String, pos::Int) = ""

# need to keep this consistent with wstype
static_type(bind::CSTParser.Binding) = static_type(bind.val)
function static_type(val::CSTParser.EXPR)
    if CSTParser.defines_function(val)
        "function"
    elseif CSTParser.defines_macro(val)
        "snippet"
    elseif CSTParser.defines_module(val)
        "module"
    elseif CSTParser.defines_struct(val) ||
           CSTParser.defines_abstract(val) ||
           CSTParser.defines_mutable(val) ||
           CSTParser.defines_primitive(val)
        "type"
    else
        isconst(val) ? "constant" : "variable"
    end
end

# need to keep this consistent with wsicon
static_icon(bind::CSTParser.Binding) = static_icon(bind.val)
function static_icon(val::CSTParser.EXPR)
    if CSTParser.defines_function(val)
        "λ"
    elseif CSTParser.defines_macro(val)
        "icon-mention"
    elseif CSTParser.defines_module(val)
        "icon-package"
    elseif CSTParser.defines_struct(val) ||
           CSTParser.defines_abstract(val) ||
           CSTParser.defines_mutable(val) ||
           CSTParser.defines_primitive(val)
        "T"
    else
        isconst(val) ? "c" : "v"
    end
end

function Base.isconst(expr::CSTParser.EXPR)
    parent = CSTParser.parentof(expr)
    parent === nothing ? false : parent.typ === CSTParser.Const
end
