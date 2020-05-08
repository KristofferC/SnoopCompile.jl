export @snoopr, invalidation_trees, explain

# This doesn't technically have to be mutable but it's more convenient for testing equality
mutable struct InstanceTree
    mi::MethodInstance
    depth::Int32
    children::Vector{InstanceTree}
    parent::InstanceTree

    # Create tree root
    function InstanceTree(mi::MethodInstance)
        new(mi, Int32(0), InstanceTree[])
    end
    # Create child
    function InstanceTree(mi::MethodInstance, depth, children, parent)
        new(mi, depth, children, parent)
    end
end
InstanceTree(mi::MethodInstance, parent::InstanceTree) = InstanceTree(mi, parent.depth+Int32(1), InstanceTree[], parent)

struct Invalidations
    instances::Vector{Pair{Any,InstanceTree}}
    tables::Vector{InstanceTree}
end
Invalidations() = Invalidations(Pair{Any,InstanceTree}[], InstanceTree[])

function countchildren(tree::InstanceTree)
    n = length(tree.children)
    for child in tree.children
        n += countchildren(child)
    end
    return n
end
countchildren(sigtree::Pair{Any,InstanceTree}) = countchildren(sigtree.second)

function countchildren(invalidations::Invalidations)
    n = 0
    for list in (invalidations.instances, invalidations.tables)
        for tree in list
            n += countchildren(tree)
        end
    end
    return n
end

# We could use AbstractTrees here, but typically one is not interested in the full tree,
# just the top method and the number of children it has
function Base.show(io::IO, invalidations::Invalidations)
    iscompact = get(io, :compact, false)
    function showlist(io, treelist, indent=0)
        n = length(treelist)
        for (i, tree) in enumerate(treelist)
            if isa(tree, Pair)
                if isa(tree.first, Type)
                    print(io, "signature ", tree.first, " triggered ")
                end
                tree = tree.second
            end
            print(io, tree.mi, " (", countchildren(tree), " children)")
            if iscompact
                i < n && print(io, ", ")
            else
                print(io, '\n')
                i < n && print(io, " "^indent)
            end
        end
    end
    
    iscompact || print(io, '\n')
    if !isempty(invalidations.instances)
        print(io, "instances: ")
        showlist(io, invalidations.instances, length("instances: "))
    end
    iscompact && print(io, "; ")
    if !isempty(invalidations.tables)
        print(io, "tables: ")
        showlist(io, invalidations.tables, length("tables: "))
    end
    iscompact && print(io, ';')
end

# dummymethod() = nothing
# dummymethod()
# const dummyinstance = which(dummymethod, ()).specializations[1]

const InvalidationData = Pair{Union{Method,MethodInstance},Invalidations}

function Base.show(io::IO, invdata::InvalidationData)
    println(io, "Defining ", invdata.first, " invalidated:")
    show(io, invdata.second)
end

function invalidation_trees(list)
    methodtrees = InvalidationData[]
    tree, sig = nothing, nothing
    invalidations = Invalidations()
    i = 0
    while i < length(list)
        item = list[i+=1]
        if isa(item, MethodInstance)
            mi = item::MethodInstance
            item = list[i+=1]
            if isa(item, Int32)
                depth = item::Int32
                if tree === nothing || iszero(depth)
                    tree = InstanceTree(mi)
                    push!(invalidations.instances, sig=>tree)
                    sig = nothing
                else
                    # Recurse back up the tree until we find the right parent
                    while tree.depth >= depth
                        tree = tree.parent
                    end
                    newtree = InstanceTree(mi, tree)
                    push!(tree.children, newtree)
                    tree = newtree
                end
            elseif item == "mt"
                tree = InstanceTree(mi)
                push!(invalidations.tables, tree)
            elseif item == "insert_backedges"
                push!(methodtrees, mi=>invalidations)
                invalidations = Invalidations()
                tree = nothing
            else
                error("unexpected item ", item)
            end
        elseif isa(item, Type)
            sig = item
        elseif isa(item, Method)
            push!(methodtrees, item=>invalidations)
            invalidations = Invalidations()
            tree = nothing
        else
            error("unexpected item ", item, " at position ", i)
        end
    end
    return sort(methodtrees; by=entry->countchildren(entry.second))
end

function explain(methodtree::InvalidationData)
    meth, invalidations = methodtree
    if isa(meth, Method)
        println("New method: ", meth)
        println("Invalidated:")
        for (sig, tree) in invalidations.instances
            if isa(sig, Type)
                println("  signature ", sig, ':')
                sigi = typeintersect(meth.sig, sig)
                println("    intersection: ", sigi)
                oldmeth = Base._methods_by_ftype(sig, -1, typemax(UInt))
                for ometh in oldmeth
                    ometh = ometh[3]
                    print("    matching method ", ometh)
                    Base.isambiguous(ometh, meth; ambiguous_bottom=true) ? println(" (ambiguous)") : println()
                end
            elseif sig === nothing
                println("    ", tree.mi)
            end
            println("  ", countchildren(tree), " direct and indirect descendants")
        end
        for tree in invalidations.tables
            println("  method table for ", tree.mi)
            println("    ", countchildren(tree), " direct and indirect descendants")
        end 
    else
        error("don't know what to do with ", meth)
    end
end

macro snoopr(expr)
    quote
        local invalidations = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
        Expr(:tryfinally,
            $(esc(expr)),
            ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
        )
        # invalidations = deepcopy(invalidations)
        # GC.gc()
        invalidations
    end
end

