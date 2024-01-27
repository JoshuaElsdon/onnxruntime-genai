#include "tests_helper.cuh"
#include "../top_p.cuh"
#include <cuda_runtime.h>
#include <curand.h>
#include <curand_kernel.h>
#include <span>

// TODO: namespaces?
// This is not really geometric decay anymore
__global__ void GeometricDecayKernel(float* logits, int vocab_size) {
  int index = threadIdx.x;
  int batch = blockIdx.x;
  for (; index < vocab_size; index += blockDim.x) {
    if (index < 5) {
      logits[batch * vocab_size + index] = 10.0f + float(index);
    } else {
      logits[batch * vocab_size + index] = 10.0f / powf(2.0f, static_cast<float>(index));
    }
  }
}

void LaunchGeometricDecayKernel(float* logits, int vocab_size, int batch_size, cudaStream_t stream) {
  int num_threads = 256;
  int num_blocks = batch_size;
  GeometricDecayKernel<<<num_blocks, num_threads, 0, stream>>>(logits, vocab_size);
}

__global__ void FisherYatesKernel(float* logits, int* indices, int vocab_size, curandState* states) {
  int shuffle_size = blockDim.x;
  int shuffle_blocks = vocab_size / shuffle_size;
  int index = threadIdx.x;
  int batch = blockIdx.x;
  // Shuffle between blocks of size blockDim.x
  curand_init(clock64(), batch * vocab_size + index, 0, &states[index]);
  for (int i = index; i < vocab_size; i += blockDim.x) {
    int random_index = (curand(&states[index]) % shuffle_blocks) * shuffle_size + index;
    float temp = logits[batch * vocab_size + i];
    logits[batch * vocab_size + i] = logits[batch * vocab_size + random_index];
    logits[batch * vocab_size + random_index] = temp;
    int temp_i = indices[batch * vocab_size + i];
    indices[batch * vocab_size + i] = indices[batch * vocab_size + random_index];
    indices[batch * vocab_size + random_index] = temp_i;
  }
  __syncthreads();
  // Shuffle within blocks of size blockDim.x
  curand_init(clock64(), batch * vocab_size + index, 0, &states[index]);
  int offset = index * shuffle_size;
  if (offset + shuffle_size <= vocab_size) { 
    for (int i = 0; i < shuffle_size; i += 1) {
      int random_index = curand(&states[index]) % shuffle_size;
      float temp = logits[batch * vocab_size + offset + i];
      logits[batch * vocab_size + offset + i] = logits[batch * vocab_size + offset + random_index];
      logits[batch * vocab_size + offset + random_index] = temp;
      int temp_i = indices[batch * vocab_size + offset + i];
      indices[batch * vocab_size + offset + i] = indices[batch * vocab_size + offset + random_index];
      indices[batch * vocab_size + offset + random_index] = temp_i;
    }
  }
}

void LaunchFisherYatesKernel(float* logits, int* indices_buffer, int vocab_size, int batch_size, cudaStream_t stream) {
  int num_threads = 256;
  int num_blocks = batch_size;
  curandState *random_states;
  cudaMalloc((void **)&random_states, num_threads * sizeof(curandState));
  std::span<float> logits_span{logits, static_cast<size_t>(vocab_size * batch_size)};
  std::span<int32_t> indices{indices_buffer, static_cast<size_t>(vocab_size * batch_size)};
  Generators::cuda::launch_populate_indices(indices.data(), vocab_size, batch_size, stream);

  // int* cpu_indices = new int[batch_size * vocab_size];
  // cudaStreamSynchronize(stream);
  // cudaMemcpy(cpu_indices, indices.data(), batch_size * vocab_size * sizeof(int), cudaMemcpyDeviceToHost);
  // for (int i = 0; i < batch_size; i++) {
  //   std::cout << "Batch " << i << "\r\n";
  //   for (int j = 0; j < 16; j++) {
  //     std::cout << cpu_indices[i * vocab_size + j] << " ";
  //   }
  //   std::cout << "\r\n";
  // }

  FisherYatesKernel<<<num_blocks, num_threads, 0, stream>>>(logits_span.data(), indices.data(), vocab_size, random_states);
}