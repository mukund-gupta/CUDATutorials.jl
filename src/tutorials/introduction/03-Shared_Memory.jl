#=
# Shared memory

**Shared memory** is the memory in a SM(symmetric multiprocessor) which is accessable to all threads running on the SM. It is much faster than global memory being much closer in proximity. The amount of shared memory available depends on the compute capability of the GPU. Increasing the amount of shared memory may reduce occupancy.

`sync_threads()` is a function which adds a [barrier](https://en.wikipedia.org/wiki/Barrier_(computer_science)) for all threads in a thread block. A **barrier** ensures that all threads which belong to it stall once they reach it until all other threads reach the barrier. This is commonly used as a synchronization mechanism to eliminate race conditions.

### Array Reversal

Our job is to reverse an array, i.e $[1, 2, 3] \rightarrow [3, 2, 1]$.
=#

using CUDA, BenchmarkTools

function reverse(input, output = similar(input))
    len = length(input)
    for i = 1:cld(len,2)
        output[i], output[len - i + 1] = input[len - i + 1], input[i]
    end
    output
end

#-

reverse([1, 2, 3, 4, 5])

#-

function gpu_reverse(input, output)
    tid = threadIdx().x
    len = length(input)
    if tid <= cld(len, 2)
        output[tid], output[len - tid + 1] = input[len - tid + 1], input[tid]
    end
    return
end

#-

A = CuArray(collect(1:5))
B = similar(A)
@cuda blocks=1 threads=length(A) gpu_reverse(A, B)
B

#=
There are two ways to declare shared memory: Statically and Dynamically. We declaring it statically when the amount we need is the same amount for all kernel launches and known when writing the kernel. In the other case we declare it dynamically and specify it while launching with the `@cuda` macro using the `shmem` argument.
=#

@doc @cuStaticSharedMem

#-


function gpu_stshmemreverse(input, output)
    ## Maximum size of array is 64
    shmem = @cuStaticSharedMem(eltype(output), 64)
    tid = threadIdx().x
    len = length(input)
    shmem[tid] = input[len - tid + 1]
    output[tid] = shmem[tid]
    return
end

#-

A = CuArray(collect(1:32))
B = similar(A)
@cuda blocks=1 threads=length(A) gpu_stshmemreverse(A, B)
print(B)

#=
When the amount of shared memory required isn't known while writing the kernel overallocating is not a good idea because that may potentially reduce our occupancy. As an SM's resource usage increases it's occupancy goes down. Hence, it's best to use dynamically allocated memory when memory usage can only be known at launch time.
=#

@doc @cuDynamicSharedMem

#-

function gpu_dyshmemreverse(input, output)
    shmem = @cuDynamicSharedMem(eltype(output), (length(output),))
    tid = threadIdx().x
    len = length(input)
    shmem[tid] = input[len - tid + 1]
    output[tid] = shmem[tid]
    return
end

#-

C = CuArray(collect(1:32))
D = similar(C)
@cuda blocks=1 threads=length(C) shmem=length(C) gpu_dyshmemreverse(C, D)
print(D)

#=
## Matrix Transpose
Matrix transpose is an operation which flips a matrix along its main diagonal.

![transpose](../assets/transpose.png)
=#

A = reshape(1:9, (3, 3))

#-

A'

#-

A'' ## (A')' 

#=
Ignore the types that Julia returns. `LinearAlgebra.Adjoint` is a wrapper that uses [lazy evaluation](https://en.wikipedia.org/wiki/Lazy_evaluation) to compute the result as required.
=#


## CPU implementation
function cpu_transpose(input, output = similar(input, (size(input, 2), size(input, 1))))
    ## the dimensions of the resultant matrix are reversed
    for index = CartesianIndices(input)
            output[index[2], index[1]] = input[index]
    end
    output
end

#-

A = reshape(1:20, (4, 5))

#-

cpu_transpose(A)

#=
Before we begin working on the GPU consider the following code.
=#

A = CuArray(reshape(1.:9, (3, 3)))

println("A => ", pointer(A))
CUDA.@allowscalar begin
    for i in eachindex(A)
        println(i, " ", A[i], " ", pointer(A, i))
    end
end

#=
Notice how consecutive elements are in the same column rather than the same row. This is because Julia stores its multidimensional arrays in a column major order like Fortran. In contrast to C/C++ which are row-major languages. The reason for making Julia's arrays column major is because a lot of linear algebra libraries are column major to begin with (https://discourse.julialang.org/t/why-column-major/24374/3).
=#


## To index our 2-D array we will split the input into tiles of 32x32 elements. 
## Each thread block will launch with 32x8 = 256 threads 
## Each thread will work on 4 elements.
const TILE_DIM = 32

function gpu_transpose_kernel(input, output)
    tile_index = ((blockIdx().y, blockIdx().x) .- 1) .* TILE_DIM
    
    ## each thread manages 4 rows (8x4 = 32)
    for i in 1:4
        thread_index = (threadIdx().y + (i - 1)*8, threadIdx().x)
        index = CartesianIndex(tile_index .+ thread_index)
        (index[1] > size(input, 1) || index[2] > size(input, 2)) && continue
        @inbounds output[index] = input[index[2], index[1]]
    end

    return
end

#-

function gpu_transpose(input, output = similar(input, (size(input, 2), size(input, 1))))
    threads = (32, 8)
    blocks = cld.(size(input), (32, 32))
    @cuda blocks=blocks threads=threads gpu_transpose_kernel(input, output)
    output
end

#-

A = CuArray(reshape(1f0:1089, 33, 33))

#-

gpu_transpose(A)

#-

A = CUDA.rand(10000, 10000)
B = similar(A)
@benchmark CUDA.@sync gpu_transpose($A, $B)

#-

@benchmark CUDA.@sync $B .= $A

#=
## Coalescing Memory Access

Compared to a simple elementwise copy we are roughly at 60% performance. Both kernels have a single load and store for each value. If all loads and stores were independent of each other then this should not have happened.

Consider a thread accessing(load or store) a single value in global memory. Instead of transferring just the one value the GPU will instead transfer a larger chunk of memory as a single transaction. For example on NVIDIA's K20 GPU this size was 128 bytes.
When threads in a warp access consecutive memory addresses the GPU can service multiple threads in the same transaction. This is known as **coalesced memory access**. Access time is effectively reduced by minimizing the number of transactions. However when threads access non-sequentially or sparse data then transactions are serialised.

We want consecutive threads of a warp to access consecutive elements in memory. When the thread block is one-dimensional it is straightforward to determine a thread's`warpId` i.e. `warpId = threadId().x % warpsize()`.
According to NVIDIA's documentation on [thread hierarchy](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#thread-hierarchy).
> The index of a thread and its thread ID relate to each other in a straightforward way: For a one-dimensional block, they are the same; for a two-dimensional block of size (Dx, Dy),the thread ID of a thread of index (x, y) is (x + y Dx); for a three-dimensional block of size (Dx, Dy, Dz), the thread ID of a thread of index (x, y, z) is (x + y Dx + z Dx Dy).


In our kernel there are four loads and stores per thread.
- `tile_index = ((blockIdx().y, blockIdx().x) .- 1) .* TILE_DIM`
- `thread_index = (threadIdx().y + (i - 1)*8, threadIdx().x)`
- `index = CartesianIndex(tile_index .+ thread_index)`
- `Load: input[index[2], index[1]]`
- `Store: output[index[1], index[2]]`

The loads are coalesced because the column is indexed by `index[2]` which has `threadIdx().x` and the stores are non-coalesced because they are indexed by `index[1]` which has `threadIdx().y`.

To ensure coalescing during both loads and stores we will use shared memory. We will load from global memory a column and store it in shared memory as a row, effectively transposing it. Once all threads have written to shared memory we can write back to global memory column wise.

![Coalesced transpose](../assets/coalesced_transpose.png)
=#


function gpu_transpose_kernel2(input, output)
    ## Declare shared memory
    shared = @cuStaticSharedMem(eltype(input), (TILE_DIM, TILE_DIM))
    
    ## Modify thread index so threadIdx().x dominates the column
    block_index = ((blockIdx().y, blockIdx().x) .- 1) .* TILE_DIM
    
    for i in 1:4
        thread_index = (threadIdx().x, threadIdx().y + (i - 1)*8)
        index = CartesianIndex(block_index .+ thread_index)

        (index[1] > size(input, 1) || index[2] > size(input, 2)) && continue
        @inbounds shared[thread_index[2], thread_index[1]] = input[index]
    end
    
    ## Barrier to ensure all threads have completed writing to shared memory
    sync_threads()
    
    ## swap tile index
    block_index = ((blockIdx().x, blockIdx().y) .- 1) .* TILE_DIM
    
    for i in 1:4 
        thread_index = (threadIdx().x, threadIdx().y + (i - 1)*8)
        index = CartesianIndex(block_index .+ thread_index)
        
        (index[1] > size(output, 1) || index[2] > size(output, 2)) && continue
        @inbounds output[index] = shared[thread_index...]
    end
    return
end

function gpu_transpose_shmem(input, output = similar(input, (size(input, 2), size(input, 1))))
    threads = (32, 8)
    blocks = cld.(size(input), (32, 32))
    @cuda blocks=blocks threads=threads gpu_transpose_kernel2(input, output)
    output
end

#-

X = CuArray(reshape(1f0:1089, (33, 33)))
Y = similar(X)
gpu_transpose_shmem(X, Y)

#-

@benchmark CUDA.@sync gpu_transpose_shmem($A, $B)

#-

@benchmark CUDA.@sync B .= A

#=
### Shared Memory Bank conflicts

Inside a SM, shared memory is divided into banks. Modern NVIDIA GPUs have 32 banks which have a 4-byte boundary. This means addresses 1-4 of shared memory are serviced by bank 1, addresses 5-8 are serviced by bank two and so on. When multiple threads access memory from the same bank then their requests are serialised.

Nsight compute gives statistics about shared memory usage. Running the profiler on `gpu_transpose_shmem` for an input of 33x33 of `Float32` we get:

![shared-memory-conflicts](../assets/shmem-conflicts.png)

It reports zero conflicts during shared loads because of we load columnwise. The 1023 store conflicts can be explained as follows. When an entire column is read it is stored to a row. Consecutive elements in a row differ in address by `column_length*sizeof(datatype)`. In 33 tile columns we write directly to a complete row where 32 elements are written hence there are 31 write conflicts (33*31 = 1023). `CUDA.jl` docs have a brief Nsight compute usage guide [here](https://juliagpu.github.io/CUDA.jl/dev/development/profiling/#NVIDIA-Nsight-Compute).

The fix is quite simple, pad the column length in shared memory by 1. Now consecutive elements in a row will differ by 33 % 32 = 1 hence no more bank conflicts.

i.e. `shared = @cuStaticSharedMem(eltype(input), (TILE_DIM + 1, TILE_DIM))`
=#

function gpu_transpose_kernel3(input, output)
    ## Declare shared memory
    shared = @cuStaticSharedMem(eltype(input), (TILE_DIM + 1, TILE_DIM))
    
    ## Modify thread index so threadIdx().x dominates the column
    block_index = ((blockIdx().y, blockIdx().x) .- 1) .* TILE_DIM
    
    for i in 1:4
        thread_index = (threadIdx().x, threadIdx().y + (i - 1)*8)
        index = CartesianIndex(block_index .+ thread_index)

        (index[1] > size(input, 1) || index[2] > size(input, 2)) && continue
        @inbounds shared[thread_index[2], thread_index[1]] = input[index]
    end
    
    ## Barrier to ensure all threads have completed writing to shared memory
    sync_threads()
    
    ## swap tile index
    block_index = ((blockIdx().x, blockIdx().y) .- 1) .* TILE_DIM
    
    for i in 1:4 
        thread_index = (threadIdx().x, threadIdx().y + (i - 1)*8)
        index = CartesianIndex(block_index .+ thread_index)
        
        (index[1] > size(output, 1) || index[2] > size(output, 2)) && continue
        @inbounds output[index] = shared[thread_index...]
    end
    return
end

function gpu_transpose_noconf(input, output = similar(input, (size(input, 2), size(input, 1))))
    threads = (32, 8)
    blocks = cld.(size(input), (32, 32))
    @cuda blocks=blocks threads=threads gpu_transpose_kernel3(input, output)
    output
end

#-

@benchmark CUDA.@sync gpu_transpose_noconf($A, $B)

#-

@benchmark CUDA.@sync gpu_transpose_shmem($A, $B)

#=
An obvious improvement, we can also confirm with Nsight compute if there are no bank conflicts.

![shmem-noconf](../assets/shmem-noconf.png)
=#
