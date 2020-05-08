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
    instances::Vector{InstanceTree}
    tables::Vector{InstanceTree}
end

function countchildren(tree::InstanceTree)
    n = length(tree.children)
    for child in tree.children
        n += countchildren(child)
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
    print(io, "instances: ")
    showlist(io, invalidations.instances, length("instances: "))
    iscompact ? print(io, "; tables: ") : print(io, "tables: ")
    showlist(io, invalidations.tables, length("tables: "))
    iscompact && print(io, ';')
end

# dummymethod() = nothing
# dummymethod()
# const dummyinstance = which(dummymethod, ()).specializations[1]

function invalidation_tree(list)
    methodtrees = Pair{Method,Invalidations}[]
    local tree
    instances, tables = InstanceTree[], InstanceTree[]
    i = 0
    while i < length(list)
        item = list[i+=1]
        if isa(item, MethodInstance)
            mi = item::MethodInstance
            item = list[i+=1]
            if isa(item, Int32)
                depth = item::Int32
                if iszero(depth)
                    tree = InstanceTree(mi)
                    push!(instances, tree)
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
                push!(tables, tree)
            else
                error("unexpected item ", item)
            end
        elseif isa(item, Method)
            push!(methodtrees, item=>Invalidations(instances, tables))
            instances, tables = InstanceTree[], InstanceTree[]
            tree = nothing
        else
            error("unexpected item ", item)
        end
    end
    return methodtrees
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

