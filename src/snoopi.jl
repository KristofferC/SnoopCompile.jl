export @snoopi

const __inf_timing__ = Tuple{Float64,MethodInstance}[]

function typeinf_ext_timed(linfo::MethodInstance, params::Core.Compiler.Params)
    tstart = time()
    ret = Core.Compiler.typeinf_ext(linfo, params)
    tstop = time()
    push!(__inf_timing__, (tstop-tstart, linfo))
    return ret
end
function typeinf_ext_timed(linfo::MethodInstance, world::UInt)
    tstart = time()
    ret = Core.Compiler.typeinf_ext(linfo, world)
    tstop = time()
    push!(__inf_timing__, (tstop-tstart, linfo))
    return ret
end

@noinline start_timing() = ccall(:jl_set_typeinf_func, Cvoid, (Any,), typeinf_ext_timed)
@noinline stop_timing() = ccall(:jl_set_typeinf_func, Cvoid, (Any,), Core.Compiler.typeinf_ext)

function sort_timed_inf(tmin)
    data = __inf_timing__
    if tmin > 0
        data = filter(tl->tl[1] >= tmin, data)
    end
    return sort(data; by=tl->tl[1])
end

"""
    inf_timing = @snoopi commands
    inf_timing = @snoopi tmin=0.0 commands

Execute `commands` while snooping on inference. Returns an array of `(t, linfo)`
tuples, where `t` is the amount of time spent infering `linfo` (a `MethodInstance`).

Methods that take less time than `tmin` will not be reported.
"""
macro snoopi(args...)
    tmin = 0.0
    if length(args) == 1
        cmd = args[1]
    elseif length(args) == 2
        a = args[1]
        if isa(a, Expr) && a.head == :(=) && a.args[1] == :tmin
            tmin = a.args[2]
            cmd = args[2]
        else
            error("unrecognized input ", a)
        end
    else
        error("at most two arguments are supported")
    end
    quote
        empty!(__inf_timing__)
        start_timing()
        try
            $(esc(cmd))
        finally
            stop_timing()
        end
        $sort_timed_inf($tmin)
    end
end

function __init__()
    # typeinf_ext_timed must be compiled before it gets run
    # We do this in __init__ to make sure it gets compiled to native code
    # (the *.ji file stores only the inferred code)
    precompile(typeinf_ext_timed, (MethodInstance, Core.Compiler.Params))
    precompile(typeinf_ext_timed, (MethodInstance, UInt))
    precompile(start_timing, ())
    precompile(stop_timing, ())
    nothing
end
