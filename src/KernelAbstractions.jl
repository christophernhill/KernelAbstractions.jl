module KernelAbstractions

export @kernel
export @Const, @localmem, @private, @uniform, @synchronize
export @index, @groupsize, @ndrange
export @print
export Device, GPU, CPU
export async_copy!, synchronize, get_device

import Atomix: @atomic, @atomicswap, @atomicreplace
import UnsafeAtomics

using LinearAlgebra
using MacroTools
using SparseArrays
using StaticArrays
using Adapt

"""
    @kernel function f(args) end

Takes a function definition and generates a Kernel constructor from it.
The enclosed function is allowed to contain kernel language constructs.
In order to call it the kernel has first to be specialized on the backend
and then invoked on the arguments.

# Kernel language

- [`@Const`](@ref)
- [`@index`](@ref)
- [`@groupsize`](@ref)
- [`@ndrange`](@ref)
- [`@localmem`](@ref)
- [`@private`](@ref)
- [`@uniform`](@ref)
- [`@synchronize`](@ref)
- [`@print`](@ref)

# Example:

```julia
@kernel function vecadd(A, @Const(B))
    I = @index(Global)
    @inbounds A[I] += B[I]
end

A = ones(1024)
B = rand(1024)
vecadd(CPU(), 64)(A, B, ndrange=size(A))
synchronize(device)
```
"""
macro kernel(expr)
    __kernel(expr)
end

"""
    @Const(A)

`@Const` is an argument annotiation that asserts that the memory reference
by `A` is both not written to as part of the kernel and that it does not alias
any other memory in the kernel.

!!! danger
    Violating those constraints will lead to arbitrary behaviour.

as an example given a kernel signature `kernel(A, @Const(B))`, you are not
allowed to call the kernel with `kernel(A, A)` or `kernel(A, view(A, :))`.
"""
macro Const end

"""
    async_copy!(::Device, dest::AbstractArray, src::AbstractArray)

Perform an asynchronous copy on the device.
"""
function async_copy! end

"""
    synchronize(::Device)

Synchronize the current device.
"""
function synchronize end


###
# Kernel language
# - @localmem
# - @private
# - @uniform
# - @synchronize
# - @index
# - @groupsize
# - @ndrange
###

function groupsize end
function ndrange end

"""
    @groupsize()

Query the workgroupsize on the device. This function returns
a tuple corresponding to kernel configuration. In order to get
the total size you can use `prod(@groupsize())`.
"""
macro groupsize()
    quote
        $groupsize($(esc(:__ctx__)))
    end 
end

"""
    @ndrange()

Query the ndrange on the device. This function returns
a tuple corresponding to kernel configuration.
"""
macro ndrange()
    quote
        $size($ndrange($(esc(:__ctx__))))
    end 
end

"""
    @localmem T dims

Declare storage that is local to a workgroup.
"""
macro localmem(T, dims)
    # Stay in sync with CUDAnative
    id = gensym("static_shmem")

    quote
        $SharedMemory($(esc(T)), Val($(esc(dims))), Val($(QuoteNode(id))))
    end
end

"""
    @private T dims

Declare storage that is local to each item in the workgroup. This can be safely used
across [`@synchronize`](@ref) statements. On a CPU, this will allocate additional implicit
dimensions to ensure correct localization.

For storage that only persists between `@synchronize` statements, an `MArray` can be used
instead.

See also [`@uniform`](@ref).
"""
macro private(T, dims)
    if dims isa Integer
        dims = (dims,)
    end
    quote
        $Scratchpad($(esc(:__ctx__)), $(esc(T)), Val($(esc(dims))))
    end
end

"""
    @private mem = 1

Creates a private local of `mem` per item in the workgroup. This can be safely used
across [`@synchronize`](@ref) statements.
"""
macro private(expr)
    esc(expr)
end

"""
    @uniform expr

`expr` is evaluated outside the workitem scope. This is useful for variable declarations
that span workitems, or are reused across `@synchronize` statements.
"""
macro uniform(value)
    esc(value)
end

"""
    @synchronize()

After a `@synchronize` statement all read and writes to global and local memory
from each thread in the workgroup are visible in from all other threads in the
workgroup.
"""
macro synchronize()
    quote
        $__synchronize()
    end
end

"""
    @synchronize(cond)

After a `@synchronize` statement all read and writes to global and local memory
from each thread in the workgroup are visible in from all other threads in the
workgroup. `cond` is not allowed to have any visible sideffects.

# Platform differences
  - `GPU`: This synchronization will only occur if the `cond` evaluates.
  - `CPU`: This synchronization will always occur.
"""
macro synchronize(cond)
    quote
        $(esc(cond)) && $__synchronize()
    end
end

"""
    @print(items...)

This is a unified print statement.

# Platform differences
  - `GPU`: This will reorganize the items to print via `@cuprintf`
  - `CPU`: This will call `print(items...)`
"""
macro print(items...)

    args = Union{Val,Expr,Symbol}[]

    items = [items...]
    while true
        isempty(items) && break

        item = popfirst!(items)

        # handle string interpolation
        if isa(item, Expr) && item.head == :string
            items = vcat(item.args, items)
            continue
        end

        # expose literals to the generator by using Val types
        if isbits(item) # literal numbers, etc
            push!(args, Val(item))
        elseif isa(item, QuoteNode) # literal symbols
            push!(args, Val(item.value))
        elseif isa(item, String) # literal strings need to be interned
            push!(args, Val(Symbol(item)))
        else # actual values that will be passed to printf
            push!(args, item)
        end
    end

    quote
        $__print($(map(esc,args)...))
    end
end

"""
    @index

The `@index` macro can be used to give you the index of a workitem within a kernel
function. It supports both the production of a linear index or a cartesian index.
A cartesian index is a general N-dimensional index that is derived from the iteration space.

# Index granularity

  - `Global`: Used to access global memory.
  - `Group`: The index of the `workgroup`.
  - `Local`: The within `workgroup` index.

# Index kind

  - `Linear`: Produces an `Int64` that can be used to linearly index into memory.
  - `Cartesian`: Produces a `CartesianIndex{N}` that can be used to index into memory.
  - `NTuple`: Produces a `NTuple{N}` that can be used to index into memory.

If the index kind is not provided it defaults to `Linear`, this is subject to change.

# Examples

```julia
@index(Global, Linear)
@index(Global, Cartesian)
@index(Local, Cartesian)
@index(Group, Linear)
@index(Local, NTuple)
@index(Global)
```
"""
macro index(locale, args...)
    if !(locale === :Global || locale === :Local || locale === :Group)
        error("@index requires as first argument either :Global, :Local or :Group")
    end

    if length(args) >= 1
        if args[1] === :Cartesian ||
           args[1] === :Linear ||
           args[1] === :NTuple
            indexkind = args[1]
            args = args[2:end]
        else
            indexkind = :Linear
        end
    else
        indexkind = :Linear
    end

    index_function = Symbol(:__index_, locale, :_, indexkind)
    Expr(:call, GlobalRef(KernelAbstractions, index_function), esc(:__ctx__), map(esc, args)...)
end

###
# Internal kernel functions
###

function __index_Local_Linear end
function __index_Group_Linear end
function __index_Global_Linear end

function __index_Local_Cartesian end
function __index_Group_Cartesian end
function __index_Global_Cartesian end

__index_Local_NTuple(ctx, I...) = Tuple(__index_Local_Cartesian(ctx, I...))
__index_Group_NTuple(ctx, I...) = Tuple(__index_Group_Cartesian(ctx, I...))
__index_Global_NTuple(ctx, I...) = Tuple(__index_Global_Cartesian(ctx, I...))

struct ConstAdaptor end

Adapt.adapt_storage(to::ConstAdaptor, a::Array) = Base.Experimental.Const(a)

constify(arg) = adapt(ConstAdaptor(), arg)

###
# Backend hierarchy
###

abstract type Device end
abstract type GPU <: Device end

struct CPU <: Device end

isgpu(::GPU) = true
isgpu(::CPU) = false


"""
    KernelAbstractions.get_device(A::AbstractArray)::KernelAbstractions.Device

Get a `KernelAbstractions.Device` instance suitable for array `A`.
"""
function get_device end

# Should cover SubArray, ReshapedArray, ReinterpretArray, Hermitian, AbstractTriangular, etc.:
get_device(A::AbstractArray) = get_device(parent(A))

get_device(A::AbstractSparseArray) = get_device(rowvals(A))
get_device(A::Diagonal) = get_device(A.diag)
get_device(A::Tridiagonal) = get_device(A.d)

get_device(::Array) = CPU()

include("nditeration.jl")
using .NDIteration
import .NDIteration: get

###
# Kernel closure struct
###

"""
    Kernel{Device, WorkgroupSize, NDRange, Func}

Kernel closure struct that is used to represent the device
kernel on the host. `WorkgroupSize` is the number of workitems
in a workgroup.
"""
struct Kernel{Device, WorkgroupSize<:_Size, NDRange<:_Size, Fun}
    f::Fun
end

function Base.similar(kernel::Kernel{D, WS, ND}, f::F) where {D, WS, ND, F}
    Kernel{D, WS, ND, F}(f)
end

workgroupsize(::Kernel{D, WorkgroupSize}) where {D, WorkgroupSize} = WorkgroupSize
ndrange(::Kernel{D, WorkgroupSize, NDRange}) where {D, WorkgroupSize,NDRange} = NDRange

function partition(kernel, ndrange, workgroupsize)
    static_ndrange = KernelAbstractions.ndrange(kernel)
    static_workgroupsize = KernelAbstractions.workgroupsize(kernel)

    if ndrange === nothing && static_ndrange <: DynamicSize ||
       workgroupsize === nothing && static_workgroupsize <: DynamicSize
        errmsg = """
            Can not partition kernel!

            You created a dynamically sized kernel, but forgot to provide runtime
            parameters for the kernel. Either provide them statically if known
            or dynamically.
            NDRange(Static):  $(static_ndrange)
            NDRange(Dynamic): $(ndrange)
            Workgroupsize(Static):  $(static_workgroupsize)
            Workgroupsize(Dynamic): $(workgroupsize)
        """
        error(errmsg)
    end

    if static_ndrange <: StaticSize
        if ndrange !== nothing && ndrange != get(static_ndrange)
            error("Static NDRange ($static_ndrange) and launch NDRange ($ndrange) differ")
        end
        ndrange = get(static_ndrange)
    end

    if static_workgroupsize <: StaticSize
        if workgroupsize !== nothing && workgroupsize != get(static_workgroupsize)
            error("Static WorkgroupSize ($static_workgroupsize) and launch WorkgroupSize $(workgroupsize) differ")
        end
        workgroupsize = get(static_workgroupsize)
    end

    @assert workgroupsize !== nothing
    @assert ndrange !== nothing
    blocks, workgroupsize, dynamic = NDIteration.partition(ndrange, workgroupsize)

    if static_ndrange <: StaticSize
        static_blocks = StaticSize{blocks}
        blocks = nothing
    else
        static_blocks = DynamicSize
        blocks = CartesianIndices(blocks)
    end

    if static_workgroupsize <: StaticSize
        static_workgroupsize = StaticSize{workgroupsize} # we might have padded workgroupsize
        workgroupsize = nothing
    else
        workgroupsize = CartesianIndices(workgroupsize)
    end

    iterspace = NDRange{length(ndrange), static_blocks, static_workgroupsize}(blocks, workgroupsize)
    return iterspace, dynamic
end

function construct(::Device, ::S, ::NDRange, xpu_name::XPUName) where {Device<:Union{CPU,GPU}, S<:_Size, NDRange<:_Size, XPUName}
    return Kernel{Device, S, NDRange, XPUName}(xpu_name)
end

###
# Compiler
###

include("compiler.jl")

###
# Compiler/Frontend
###

function __workitems_iterspace end
function __validindex end

include("macros.jl")

###
# Backends/Interface
###

function Scratchpad end
function SharedMemory end

function __synchronize()
    error("@synchronize used outside kernel or not captured")
end

@generated function __print(items...)
    str = ""
    args = []

    for i in 1:length(items)
        item = :(items[$i])
        T = items[i]
        if T <: Val
            item = QuoteNode(T.parameters[1])
        end
        push!(args, item)
    end

    quote
        print($(args...))
    end
end

# Utils
__size(args::Tuple) = Tuple{args...}
__size(i::Int) = Tuple{i}

###
# Extras
# - LoopInfo
###

include("extras/extras.jl")

include("reflection.jl")

# CPU backend

include("cpu.jl")

end #module
