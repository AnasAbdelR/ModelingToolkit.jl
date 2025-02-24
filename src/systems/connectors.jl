get_connection_type(s) = getmetadata(unwrap(s), VariableConnectType, Equality)

function with_connector_type(expr)
    @assert expr isa Expr && (expr.head == :function || (expr.head == :(=) &&
                                       expr.args[1] isa Expr &&
                                       expr.args[1].head == :call))

    sig = expr.args[1]
    body = expr.args[2]

    fname = sig.args[1]
    args = sig.args[2:end]

    quote
        function $fname($(args...))
            function f()
                $body
            end
            res = f()
            $isdefined(res, :connector_type) && $getfield(res, :connector_type) === nothing ? $Setfield.@set!(res.connector_type = $connector_type(res)) : res
        end
    end
end

macro connector(expr)
    esc(with_connector_type(expr))
end

abstract type AbstractConnectorType end
struct StreamConnector <: AbstractConnectorType end
struct RegularConnector <: AbstractConnectorType end

function connector_type(sys::AbstractSystem)
    sts = get_states(sys)
    #TODO: check the criteria for stream connectors
    n_stream = 0
    n_flow = 0
    for s in sts
        vtype = get_connection_type(s)
        if vtype === Stream
            isarray(s) && error("Array stream variables are not supported. Got $s.")
            n_stream += 1
        end
        vtype === Flow && (n_flow += 1)
    end
    (n_stream > 0 && n_flow > 1) && error("There are multiple flow variables in $(nameof(sys))!")
    n_stream > 0 ? StreamConnector() : RegularConnector()
end

Base.@kwdef struct Connection
    inners = nothing
    outers = nothing
end

# everything is inner by default until we expand the connections
Connection(syss) = Connection(inners=syss)
get_systems(c::Connection) = c.inners
function Base.in(e::Symbol, c::Connection)
    (c.inners !== nothing && any(k->nameof(k) === e, c.inners)) ||
    (c.outers !== nothing && any(k->nameof(k) === e, c.outers))
end

function renamespace(sym::Symbol, connection::Connection)
    inners = connection.inners === nothing ? [] : renamespace.(sym, connection.inners)
    if connection.outers !== nothing
        for o in connection.outers
            push!(inners, renamespace(sym, o))
        end
    end
    Connection(;inners=inners)
end

const EMPTY_VEC = []

function Base.show(io::IO, ::MIME"text/plain", c::Connection)
    # It is a bit unfortunate that the display of an array of `Equation`s won't
    # call this.
    @unpack outers, inners = c
    if outers === nothing && inners === nothing
        print(io, "<Connection>")
    else
        syss = Iterators.flatten((something(inners, EMPTY_VEC), something(outers, EMPTY_VEC)))
        splitting_idx = length(inners)
        sys_str = join((string(nameof(s)) * (i <= splitting_idx ? ("::inner") : ("::outer")) for (i, s) in enumerate(syss)), ", ")
        print(io, "<", sys_str, ">")
    end
end

# symbolic `connect`
function connect(sys1::AbstractSystem, sys2::AbstractSystem, syss::AbstractSystem...)
    syss = (sys1, sys2, syss...)
    length(unique(nameof, syss)) == length(syss) || error("connect takes distinct systems!")
    Equation(Connection(), Connection(syss)) # the RHS are connected systems
end

instream(a) = term(instream, unwrap(a), type=symtype(a))
SymbolicUtils.promote_symtype(::typeof(instream), _) = Real

isconnector(s::AbstractSystem) = has_connector_type(s) && get_connector_type(s) !== nothing
isstreamconnector(s::AbstractSystem) = isconnector(s) && get_connector_type(s) isa StreamConnector
isstreamconnection(c::Connection) = any(isstreamconnector, c.inners) || any(isstreamconnector, c.outers)

function print_with_indent(n, x)
    print(" " ^ n)
    show(stdout, MIME"text/plain"(), x)
    println()
end

function split_sys_var(var)
    var_name = string(getname(var))
    sidx = findlast(isequal('₊'), var_name)
    sidx === nothing && error("$var is not a namespaced variable")
    connector_name = Symbol(var_name[1:prevind(var_name, sidx)])
    streamvar_name = Symbol(var_name[nextind(var_name, sidx):end])
    connector_name, streamvar_name
end

function flowvar(sys::AbstractSystem)
    sts = get_states(sys)
    for s in sts
        vtype = get_connection_type(s)
        vtype === Flow && return s
    end
    error("There in no flow variable in $(nameof(sys))")
end

collect_instream!(set, eq::Equation) = collect_instream!(set, eq.lhs) | collect_instream!(set, eq.rhs)

function collect_instream!(set, expr, occurs=false)
    istree(expr) || return occurs
    op = operation(expr)
    op === instream && (push!(set, expr); occurs = true)
    for a in SymbolicUtils.unsorted_arguments(expr)
        occurs |= collect_instream!(set, a, occurs)
    end
    return occurs
end

#positivemax(m, ::Any; tol=nothing)= max(m, something(tol, 1e-8))
#_positivemax(m, tol) = ifelse((-tol <= m) & (m <= tol), ((3 * tol - m) * (tol + m)^3)/(16 * tol^3) + tol, max(m, tol))
function _positivemax(m, si)
    T = typeof(m)
    relativeTolerance = 1e-4
    nominal = one(T)
    eps = relativeTolerance * nominal
    alpha = if si > eps
        one(T)
    else
        if si > 0
            (si/eps)^2*(3-2* si/eps)
        else
            zero(T)
        end
    end
    alpha * max(m, 0) + (1-alpha)*eps
end
@register _positivemax(m, tol)
positivemax(m, ::Any; tol=nothing) = _positivemax(m, tol)
mydiv(num, den) = if den == 0
    error()
else
    num / den
end
@register mydiv(n, d)

function generate_isouter(sys::AbstractSystem)
    outer_connectors = Symbol[]
    for s in get_systems(sys)
        n = nameof(s)
        isconnector(s) && push!(outer_connectors, n)
    end
    let outer_connectors=outer_connectors
        function isouter(sys)::Bool
            s = string(nameof(sys))
            isconnector(sys) || error("$s is not a connector!")
            idx = findfirst(isequal('₊'), s)
            parent_name = Symbol(idx === nothing ? s : s[1:prevind(s, idx)])
            parent_name in outer_connectors
        end
    end
end

struct LazyNamespace
    namespace::Union{Nothing,Symbol}
    sys
end

Base.copy(l::LazyNamespace) = renamespace(l.namespace, l.sys)
Base.nameof(l::LazyNamespace) = renamespace(l.namespace, nameof(l.sys))

struct ConnectionElement
    sys::LazyNamespace
    v
    isouter::Bool
end
Base.hash(l::ConnectionElement, salt::UInt) = hash(nameof(l.sys)) ⊻ hash(l.v) ⊻ hash(l.isouter) ⊻ salt
Base.isequal(l1::ConnectionElement, l2::ConnectionElement) = l1 == l2
Base.:(==)(l1::ConnectionElement, l2::ConnectionElement) = nameof(l1.sys) == nameof(l2.sys) && isequal(l1.v, l2.v) && l1.isouter == l2.isouter
namespaced_var(l::ConnectionElement) = states(l, l.v)
states(l::ConnectionElement, v) = states(copy(l.sys), v)

struct ConnectionSet
    set::Vector{ConnectionElement} # namespace.sys, var, isouter
end

function Base.show(io::IO, c::ConnectionSet)
    print(io, "<")
    for i in 1:length(c.set)-1
        @unpack sys, v, isouter = c.set[i]
        print(io, nameof(sys), ".", v, "::", isouter ? "outer" : "inner", ", ")
    end
    @unpack sys, v, isouter = last(c.set)
    print(io, nameof(sys), ".", v, "::", isouter ? "outer" : "inner", ">")
end

@noinline connection_error(ss) = error("Different types of connectors are in one conenction statement: <$(map(nameof, ss))>")

function connection2set!(connectionsets, namespace, ss, isouter)
    nn = map(nameof, ss)
    sts1 = Set(states(first(ss)))
    T = ConnectionElement
    csets = [T[] for _ in 1:length(sts1)]
    for (i, s) in enumerate(ss)
        sts = states(s)
        i != 1 && ((length(sts1) == length(sts) && all(Base.Fix2(in, sts1), sts)) || connection_error(ss))
        io = isouter(s)
        for (j, v) in enumerate(sts)
            push!(csets[j], T(LazyNamespace(namespace, s), v, io))
        end
    end
    for cset in csets
        vtype = get_connection_type(first(cset).v)
        for k in 2:length(cset)
            vtype === get_connection_type(cset[k].v) || connection_error(ss)
        end
        push!(connectionsets, ConnectionSet(cset))
    end
end

function generate_connection_set(sys::AbstractSystem)
    connectionsets = ConnectionSet[]
    sys = generate_connection_set!(connectionsets, sys)
    sys, merge(connectionsets)
end

function generate_connection_set!(connectionsets, sys::AbstractSystem, namespace=nothing)
    subsys = get_systems(sys)

    isouter = generate_isouter(sys)
    eqs′ = get_eqs(sys)
    eqs = Equation[]

    cts = [] # connections
    for eq in eqs′
        if eq.lhs isa Connection
            push!(cts, get_systems(eq.rhs))
        else
            push!(eqs, eq) # split connections and equations
        end
    end

    if namespace !== nothing
        # Except for the top level, all connectors are eventually inside
        # connectors.
        T = ConnectionElement
        for s in subsys
            isconnector(s) || continue
            for v in states(s)
                Flow === get_connection_type(v) || continue
                push!(connectionsets, ConnectionSet([T(LazyNamespace(namespace, s), v, false)]))
            end
        end
    end

    for ct in cts
        connection2set!(connectionsets, namespace, ct, isouter)
    end

    # pre order traversal
    @set! sys.systems = map(s->generate_connection_set!(connectionsets, s, renamespace(namespace, nameof(s))), subsys)
    @set! sys.eqs = eqs
end

function Base.merge(csets::AbstractVector{<:ConnectionSet})
    mcsets = ConnectionSet[]
    ele2idx = Dict{ConnectionElement,Int}()
    cacheset = Set{ConnectionElement}()
    for cset in csets
        idx = nothing
        for e in cset.set
            idx = get(ele2idx, e, nothing)
            idx !== nothing && break
        end
        if idx === nothing
            push!(mcsets, cset)
            for e in cset.set
                ele2idx[e] = length(mcsets)
            end
        else
            for e in mcsets[idx].set
                push!(cacheset, e)
            end
            for e in cset.set
                push!(cacheset, e)
            end
            empty!(mcsets[idx].set)
            for e in cacheset
                ele2idx[e] = idx
                push!(mcsets[idx].set, e)
            end
            empty!(cacheset)
        end
    end
    mcsets
end

function generate_connection_equations_and_stream_connections(csets::AbstractVector{<:ConnectionSet})
    eqs = Equation[]
    stream_connections = ConnectionSet[]

    for cset in csets
        v = cset.set[1].v
        if hasmetadata(v, Symbolics.GetindexParent)
            v = getparent(v)
        end
        vtype = get_connection_type(v)
        if vtype === Stream
            push!(stream_connections, cset)
            continue
        elseif vtype === Flow
            rhs = 0
            for ele in cset.set
                v = namespaced_var(ele)
                rhs += ele.isouter ? -v : v
            end
            push!(eqs, 0 ~ rhs)
        else # Equality
            base = namespaced_var(cset.set[1])
            for i in 2:length(cset.set)
                v = namespaced_var(cset.set[i])
                push!(eqs, base ~ v)
            end
        end
    end
    eqs, stream_connections
end

function expand_connections(sys::AbstractSystem; debug=false, tol=1e-10)
    sys, csets = generate_connection_set(sys)
    ceqs, instream_csets = generate_connection_equations_and_stream_connections(csets)
    _sys = expand_instream(instream_csets, sys; debug=debug, tol=tol)
    sys = flatten(sys, true)
    @set! sys.eqs = [equations(_sys); ceqs]
end

function unnamespace(root, namespace)
    root === nothing && return namespace
    root = string(root)
    namespace = string(namespace)
    if length(namespace) > length(root)
        @assert root == namespace[1:length(root)]
        Symbol(namespace[nextind(namespace, length(root)):end])
    else
        @assert root == namespace
        nothing
    end
end

function expand_instream(csets::AbstractVector{<:ConnectionSet}, sys::AbstractSystem, namespace=nothing, prevnamespace=nothing; debug=false, tol=1e-8)
    subsys = get_systems(sys)
    # post order traversal
    @set! sys.systems = map(s->expand_instream(csets, s, renamespace(namespace, nameof(s)), namespace; debug, tol), subsys)
    subsys = get_systems(sys)

    if debug
        @info "Expanding" namespace
    end

    sub = Dict()
    eqs = Equation[]
    instream_eqs = Equation[]
    instream_exprs = Set()
    for s in subsys
        for eq in get_eqs(s)
            eq = namespace_equation(eq, s)
            if collect_instream!(instream_exprs, eq)
                push!(instream_eqs, eq)
            else
                push!(eqs, eq)
            end
        end

    end

    for ex in instream_exprs
        cset, idx_in_set, sv = get_cset_sv(namespace, ex, csets)

        n_inners = n_outers = 0
        for (i, e) in enumerate(cset)
            if e.isouter
                n_outers += 1
            else
                n_inners += 1
            end
        end
        if debug
            @info "Expanding at [$idx_in_set]" ex ConnectionSet(cset)
            @show n_inners, n_outers
        end
        if n_inners == 1 && n_outers == 0
            sub[ex] = sv
        elseif n_inners == 2 && n_outers == 0
            other = idx_in_set == 1 ? 2 : 1
            sub[ex] = get_current_var(namespace, cset[other], sv)
        elseif n_inners == 1 && n_outers == 1
            if !cset[idx_in_set].isouter
                other = idx_in_set == 1 ? 2 : 1
                outerstream = get_current_var(namespace, cset[other], sv)
                sub[ex] = instream(outerstream)
            end
        else
            if !cset[idx_in_set].isouter
                fv = flowvar(first(cset).sys.sys)
                # mj.c.m_flow
                innerfvs = [get_current_var(namespace, s, fv) for (j, s) in enumerate(cset) if j != idx_in_set && !s.isouter]
                innersvs = [get_current_var(namespace, s, sv) for (j, s) in enumerate(cset) if j != idx_in_set && !s.isouter]
                # ck.m_flow
                outerfvs = [get_current_var(namespace, s, fv) for s in cset if s.isouter]
                outersvs = [get_current_var(namespace, s, sv) for s in cset if s.isouter]

                sub[ex] = term(instream_rt, Val(length(innerfvs)), Val(length(outerfvs)), innerfvs..., innersvs..., outerfvs..., outersvs...)
            end
        end
    end

    # additional equations
    additional_eqs = Equation[]
    csets = filter(cset->any(e->e.sys.namespace === namespace, cset.set), csets)
    for cset′ in csets
        cset = cset′.set
        connectors = Vector{Any}(undef, length(cset))
        n_inners = n_outers = 0
        for (i, e) in enumerate(cset)
            connectors[i] = e.sys.sys
            if e.isouter
                n_outers += 1
            else
                n_inners += 1
            end
        end
        iszero(n_outers) && continue
        connector_representative = first(cset).sys.sys
        fv = flowvar(connector_representative)
        sv = first(cset).v
        vtype = get_connection_type(sv)
        vtype === Stream || continue
        if n_inners == 1 && n_outers == 1
            push!(additional_eqs, states(cset[1].sys.sys, sv) ~ states(cset[2].sys.sys, sv))
        elseif n_inners == 0 && n_outers == 2
            # we don't expand `instream` in this case.
            v1 = states(cset[1].sys.sys, sv)
            v2 = states(cset[2].sys.sys, sv)
            push!(additional_eqs, v1 ~ instream(v2))
            push!(additional_eqs, v2 ~ instream(v1))
        else
            sq = 0
            s_inners = (s for s in cset if !s.isouter)
            s_outers = (s for s in cset if s.isouter)
            for (q, oscq) in enumerate(s_outers)
                sq += sum(s->max(-states(s, fv), 0), s_inners)
                for (k, s) in enumerate(s_outers); k == q && continue
                    f = states(s.sys.sys, fv)
                    sq += max(f, 0)
                end

                num = 0
                den = 0
                for s in s_inners
                    f = states(s.sys.sys, fv)
                    tmp = positivemax(-f, sq; tol=tol)
                    den += tmp
                    num += tmp * states(s.sys.sys, sv)
                end
                for (k, s) in enumerate(s_outers); k == q && continue
                    f = states(s.sys.sys, fv)
                    tmp = positivemax(f, sq; tol=tol)
                    den += tmp
                    num += tmp * instream(states(s.sys.sys, sv))
                end
                push!(additional_eqs, states(oscq.sys.sys, sv) ~ num / den)
            end
        end
    end

    subed_eqs = substitute(instream_eqs, sub)
    if debug && !(isempty(csets) && isempty(additional_eqs) && isempty(instream_eqs))
        println("======================================")
        @info "Additional equations" csets
        display(additional_eqs)
        println("======================================")
        println("Substitutions")
        display(sub)
        println("======================================")
        println("Substituted equations")
        foreach(i->println(instream_eqs[i] => subed_eqs[i]), eachindex(subed_eqs))
        println("======================================")
    end

    @set! sys.systems = []
    @set! sys.eqs = [get_eqs(sys); eqs; subed_eqs; additional_eqs]
    sys
end

function get_current_var(namespace, cele, sv)
    states(renamespace(unnamespace(namespace, cele.sys.namespace), cele.sys.sys), sv)
end

function get_cset_sv(namespace, ex, csets)
    ns_sv = only(arguments(ex))
    full_name_sv = renamespace(namespace, ns_sv)

    cidx = -1
    idx_in_set = -1
    sv = ns_sv
    for (i, c) in enumerate(csets)
        crep = first(c.set)
        current = namespace == crep.sys.namespace
        for (j, v) in enumerate(c.set)
            if isequal(namespaced_var(v), full_name_sv) && (current || !v.isouter)
                cidx = i
                idx_in_set = j
                sv = v.v
            end
        end
    end
    cidx < 0 && error("$ns_sv is not a variable inside stream connectors")
    cset = csets[cidx].set
    #if namespace != first(cset).sys.namespace
    #    cset = map(c->@set(c.isouter = false), cset)
    #end
    cset, idx_in_set, sv
end

# instream runtime
@generated function _instream_split(::Val{inner_n}, ::Val{outer_n}, vars::NTuple{N,Any}) where {inner_n, outer_n, N}
    #instream_rt(innerfvs..., innersvs..., outerfvs..., outersvs...)
    ret = Expr(:tuple)
    # mj.c.m_flow
    inner_f = :(Base.@ntuple $inner_n i -> vars[i])
    offset = inner_n
    inner_s = :(Base.@ntuple $inner_n i -> vars[$offset+i])
    offset += inner_n
    # ck.m_flow
    outer_f = :(Base.@ntuple $outer_n i -> vars[$offset+i])
    offset += outer_n
    outer_s = :(Base.@ntuple $outer_n i -> vars[$offset+i])
    Expr(:tuple, inner_f, inner_s, outer_f, outer_s)
end

function instream_rt(ins::Val{inner_n}, outs::Val{outer_n}, vars::Vararg{Any,N}) where {inner_n, outer_n, N}
    @assert N == 2*(inner_n + outer_n)

    # inner: mj.c.m_flow
    # outer: ck.m_flow
    inner_f, inner_s, outer_f, outer_s = _instream_split(ins, outs, vars)

    T = float(first(inner_f))
    si = zero(T)
    num = den = zero(T)
    for f in inner_f
        si += max(-f, 0)
    end
    for f in outer_f
        si += max(f, 0)
    end
    #for (f, s) in zip(inner_f, inner_s)
    for j in 1:inner_n
        @inbounds f = inner_f[j]
        @inbounds s = inner_s[j]
        num += _positivemax(-f, si) * s
        den += _positivemax(-f, si)
    end
    #for (f, s) in zip(outer_f, outer_s)
    for j in 1:outer_n
        @inbounds f = outer_f[j]
        @inbounds s = outer_s[j]
        num += _positivemax(-f, si) * s
        den += _positivemax(-f, si)
    end
    return num / den
    #=
    si = sum(max(-mj.c.m_flow,0) for j in cat(1,1:i-1, i+1:N)) +
            sum(max(ck.m_flow ,0) for k  in 1:M)

    inStream(mi.c.h_outflow) =
       (sum(positiveMax(-mj.c.m_flow,si)*mj.c.h_outflow)
      +  sum(positiveMax(ck.m_flow,s_i)*inStream(ck.h_outflow)))/
     (sum(positiveMax(-mj.c.m_flow,s_i))
        +  sum(positiveMax(ck.m_flow,s_i)))
                  for j in 1:N and i <> j and mj.c.m_flow.min < 0,
                  for k in 1:M and ck.m_flow.max > 0
    =#
end
SymbolicUtils.promote_symtype(::typeof(instream_rt), ::Vararg) = Real
