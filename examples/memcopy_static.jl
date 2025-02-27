using KernelAbstractions, Test
include(joinpath(dirname(pathof(KernelAbstractions)), "../examples/utils.jl")) # Load backend

@kernel function copy_kernel!(A, @Const(B))
    I = @index(Global)
    @inbounds A[I] = B[I]
end

function mycopy_static!(A::Array, B::Array)
    @assert size(A) == size(B)
    kernel = copy_kernel!(CPU(), 32, size(A)) # if size(A) varies this will cause recompilation
    kernel(A, B, ndrange=size(A))
end

A = zeros(128, 128)
B = ones(128, 128)
mycopy_static!(A, B)
KernelAbstractions.synchronize(KernelAbstractions.get_device(A))
@test A == B

if has_cuda && has_cuda_gpu()

    function mycopy_static!(A::CuArray, B::CuArray)
        @assert size(A) == size(B)
        kernel = copy_kernel!(CUDADevice(), 32, size(A)) # if size(A) varies this will cause recompilation
        kernel(A, B, ndrange=size(A))
    end

    A = CuArray{Float32}(undef, 1024)
    B = CUDA.ones(Float32, 1024)
    mycopy_static!(A, B)
    KernelAbstractions.synchronize(KernelAbstractions.get_device(A))
    @test A == B
end
