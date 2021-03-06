/*
Copyright (c) 2014, Texas State University. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted for academic, research, experimental, or personal use provided
that the following conditions are met:

   * Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
   * Neither the name of Texas State University nor the names of its
     contributors may be used to endorse or promote products derived from this
     software without specific prior written permission.

For all other uses, please contact the Office for Commercialization and Industry
Relations at Texas State University <http://www.txstate.edu/ocir/>.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Author: Martin Burtscher
*/


#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
#include <sys/time.h>
#include <cuda.h>
#include <curand_kernel.h>

// no point in using precise FP math or double precision as we are rounding
// the results to the nearest integer anyhow

/******************************************************************************/
/*** 2-opt with random restarts ***********************************************/
/******************************************************************************/

#define tilesize 128
#define dist(a, b) __float2int_rn(sqrtf((px[a] - px[b]) * (px[a] - px[b]) + (py[a] - py[b]) * (py[a] - py[b])))
#define swap(a, b) {float tmp = a;  a = b;  b = tmp;}

static __device__ int climbs_d;
static __device__ volatile int best_d;
static __device__ int lock_d;
static __device__ float *soln_d;
extern __shared__ int buf_s[];

static __global__ void Init()
{
  climbs_d = 0;
  best_d = INT_MAX;
  lock_d = 0;
  soln_d = NULL;
}
/*
  This function assigns a single "climber" to a block of threads, meaning
  that if there are 10 blocks of threads, TwoOpt will randomize 10 topologies,
  and then use the threads in that block to perform the TwoOpt moves in parallel.

  The number of blocks TwoOpt will use is given by "restarts" taken in on the
  command line, and the number of threads per block is calculated by the
  best_thread_count function.

  For our solver, we will also take in a number of restarts, but we will
  sequentially randomize a topology, sequentially perform TwoOpt moves until
  no better TwoOpt moves can be found, and then we will compare this local
  optimum to the global best, and store the new solution if it's better
  (store cost, and tour). If it's the first restart, we'll just store
  it as best.
*/
static __global__ __launch_bounds__(1024, 2)
void TwoOpt(int cities, float *posx_d, float *posy_d, int *glob_d)
{
  int *buf = &glob_d[blockIdx.x * ((3 * cities + 2 + 31) / 32 * 32)];
  float *px = (float *)(&buf[cities]);
  float *py = &px[cities + 1];
  /*
    px_s and py_s are x and y coord arrays shared between threads,
    maybe a buffer?
  */
  __shared__ float px_s[tilesize];
  __shared__ float py_s[tilesize];
  __shared__ int bf_s[tilesize];

  //Each thread will perform these instructions in parallel, i.e. thread 0, 1, 2, 3, 4
  //will load posx_d[0,1,2,3,4] to px[0,1,2,3,4] in parallel, then thread 0 will load
  //posx_d[5] to px[5] and so on. These two lines copy posx_d and posy_d to px
  //and py in parallel. The entire array gets copied.
  for (int i = threadIdx.x; i < cities; i += blockDim.x) px[i] = posx_d[i];
  for (int i = threadIdx.x; i < cities; i += blockDim.x) py[i] = posy_d[i];
  __syncthreads();

  //Thread 0 (in each block) loops through the coordinate arrays and randomizes
  //the tour for the block.
  if (threadIdx.x == 0) {  // serial permutation
    curandState rndstate;
    curand_init(blockIdx.x, 0, 0, &rndstate);
    for (int i = 1; i < cities; i++) {
      int j = curand(&rndstate) % (cities - 1) + 1;
      swap(px[i], px[j]);
      swap(py[i], py[j]);
    }
    px[cities] = px[0];
    py[cities] = py[0];
  }
  __syncthreads();

  int minchange;
  do {
    for (int i = threadIdx.x; i < cities; i += blockDim.x) buf[i] = -dist(i, i + 1);
    __syncthreads();

    minchange = 0;
    int mini = 1;
    int minj = 0;
    for (int ii = 0; ii < cities - 2; ii += blockDim.x) {
      int i = ii + threadIdx.x;
      float pxi0, pyi0, pxi1, pyi1, pxj1, pyj1;
      if (i < cities - 2) {
        minchange -= buf[i];
        pxi0 = px[i];
        pyi0 = py[i];
        pxi1 = px[i + 1];
        pyi1 = py[i + 1];
        pxj1 = px[cities];
        pyj1 = py[cities];
      }
      for (int jj = cities - 1; jj >= ii + 2; jj -= tilesize) {
        int bound = jj - tilesize + 1;
        for (int k = threadIdx.x; k < tilesize; k += blockDim.x) {
          if (k + bound >= ii + 2) {
            px_s[k] = px[k + bound];
            py_s[k] = py[k + bound];
            bf_s[k] = buf[k + bound];
          }
        }
        __syncthreads();

        int lower = bound;
        if (lower < i + 2) lower = i + 2;
        for (int j = jj; j >= lower; j--) {
          int jm = j - bound;
          float pxj0 = px_s[jm];
          float pyj0 = py_s[jm];
          int change = bf_s[jm]
            + __float2int_rn(sqrtf((pxi0 - pxj0) * (pxi0 - pxj0) + (pyi0 - pyj0) * (pyi0 - pyj0)))
            + __float2int_rn(sqrtf((pxi1 - pxj1) * (pxi1 - pxj1) + (pyi1 - pyj1) * (pyi1 - pyj1)));
          pxj1 = pxj0;
          pyj1 = pyj0;
          if (minchange > change) {
            minchange = change;
            mini = i;
            minj = j;
          }
        }
        __syncthreads();
      }

      if (i < cities - 2) {
        minchange += buf[i];
      }
    }
    __syncthreads();

    int change = buf_s[threadIdx.x] = minchange;
    if (threadIdx.x == 0) atomicAdd(&climbs_d, 1);  // stats only
    __syncthreads();

    int j = blockDim.x;
    do {
      int k = (j + 1) / 2;
      if ((threadIdx.x + k) < j) {
        int tmp = buf_s[threadIdx.x + k];
        if (change > tmp) change = tmp;
        buf_s[threadIdx.x] = change;
      }
      j = k;
      __syncthreads();
    } while (j > 1);

    if (minchange == buf_s[0]) {
      buf_s[1] = threadIdx.x;  // non-deterministic winner
    }
    __syncthreads();

    if (threadIdx.x == buf_s[1]) {
      buf_s[2] = mini + 1;
      buf_s[3] = minj;
    }
    __syncthreads();

    minchange = buf_s[0];
    mini = buf_s[2];
    int sum = buf_s[3] + mini;
    for (int i = threadIdx.x; (i + i) < sum; i += blockDim.x) {
      if (mini <= i) {
        int j = sum - i;
        swap(px[i], px[j]);
        swap(py[i], py[j]);
      }
    }
    __syncthreads();
  } while (minchange < 0);

  int term = 0;
  for (int i = threadIdx.x; i < cities; i += blockDim.x) {
    term += dist(i, i + 1);
  }
  buf_s[threadIdx.x] = term;
  __syncthreads();

  int j = blockDim.x;
  do {
    int k = (j + 1) / 2;
    if ((threadIdx.x + k) < j) {
      term += buf_s[threadIdx.x + k];
    }
    __syncthreads();
    if ((threadIdx.x + k) < j) {
      buf_s[threadIdx.x] = term;
    }
    j = k;
    __syncthreads();
  } while (j > 1);

  if (threadIdx.x == 0) {
    atomicMin((int *)&best_d, term);
    if (best_d == term) {
      while (atomicExch(&lock_d, 1) != 0);  // acquire
      if (best_d == term) {
        soln_d = px;
      }
      lock_d = 0;  // release
      __threadfence();
    }
  }
}

/******************************************************************************/
/*** find best thread count ***************************************************/
/******************************************************************************/

static int best_thread_count(int cities)
{
  int max, best, threads, smem, blocks, thr, perf, bthr;

  max = cities - 2;//
  if (max > 1024) max = 1024;
  best = 0;
  bthr = 4;
  for (threads = 1; threads <= max; threads++) {
    smem = sizeof(int) * threads + 2 * sizeof(float) * tilesize + sizeof(int) * tilesize;
    blocks = (16384 * 2) / smem;
    if (blocks > 16) blocks = 16;
    thr = (threads + 31) / 32 * 32;
    while (blocks * thr > 2048) blocks--;
    perf = threads * blocks;
    if (perf > best) {
      best = perf;
      bthr = threads;
    }
  }

  return bthr;
}

/******************************************************************************/
/*** helper code **************************************************************/
/******************************************************************************/

static void CudaTest(char *msg)
{
  cudaError_t e;

  cudaThreadSynchronize();
  if (cudaSuccess != (e = cudaGetLastError())) {
    fprintf(stderr, "%s: %d\n", msg, e);
    fprintf(stderr, "%s\n", cudaGetErrorString(e));
    exit(-1);
  }
}

#define mallocOnGPU(addr, size) if (cudaSuccess != cudaMalloc((void **)&addr, size)) fprintf(stderr, "could not allocate GPU memory\n");  CudaTest("couldn't allocate GPU memory");
#define copyToGPU(to, from, size) if (cudaSuccess != cudaMemcpy(to, from, size, cudaMemcpyHostToDevice)) fprintf(stderr, "copying of data to device failed\n");  CudaTest("data copy to device failed");
#define copyFromGPU(to, from, size) if (cudaSuccess != cudaMemcpy(to, from, size, cudaMemcpyDeviceToHost)) fprintf(stderr, "copying of data from device failed\n");  CudaTest("data copy from device failed");
#define copyFromGPUSymbol(to, from, size) if (cudaSuccess != cudaMemcpyFromSymbol(to, from, size)) fprintf(stderr, "copying of symbol from device failed\n");  CudaTest("symbol copy from device failed");
#define copyToGPUSymbol(to, from, size) if (cudaSuccess != cudaMemcpyToSymbol(to, from, size)) fprintf(stderr, "copying of symbol to device failed\n");  CudaTest("symbol copy to device failed");

/******************************************************************************/
/*** read TSPLIB input ********************************************************/
/******************************************************************************/

static int readInput(char *fname, float **posx_d, float **posy_d)  // ATT and CEIL_2D edge weight types are not supported
{
  int ch, cnt, in1, cities;
  float in2, in3;
  FILE *f;
  float *posx, *posy;//Don't need these in TSP_CPU
  char str[256];  // potential for buffer overrun

  f = fopen(fname, "rt");
  if (f == NULL) {fprintf(stderr, "could not open file %s\n", fname);  exit(-1);}

  //Skip 3 lines in input file
  ch = getc(f);  while ((ch != EOF) && (ch != '\n')) ch = getc(f);
  ch = getc(f);  while ((ch != EOF) && (ch != '\n')) ch = getc(f);
  ch = getc(f);  while ((ch != EOF) && (ch != '\n')) ch = getc(f);

  //Read until the ':' on line 4, and discard what was read
  ch = getc(f);  while ((ch != EOF) && (ch != ':')) ch = getc(f);
  fscanf(f, "%s\n", str);//Read the rest of line 4 to str
  cities = atoi(str);//Set cities to the number read-> "DIMENSION: " in input file
  if (cities <= 2) {fprintf(stderr, "only %d cities\n", cities);  exit(-1);}

  posx = (float *)malloc(sizeof(float) * cities);  if (posx == NULL) {fprintf(stderr, "cannot allocate posx\n");  exit(-1);}
  posy = (float *)malloc(sizeof(float) * cities);  if (posy == NULL) {fprintf(stderr, "cannot allocate posy\n");  exit(-1);}

  ch = getc(f);  while ((ch != EOF) && (ch != '\n')) ch = getc(f);
  fscanf(f, "%s\n", str);
  if (strcmp(str, "NODE_COORD_SECTION") != 0) {fprintf(stderr, "wrong file format\n");  exit(-1);}

  cnt = 0;
  while (fscanf(f, "%d %f %f\n", &in1, &in2, &in3)) {
    posx[cnt] = in2;
    posy[cnt] = in3;
    cnt++;
    if (cnt > cities) {fprintf(stderr, "input too long\n");  exit(-1);}
    if (cnt != in1) {fprintf(stderr, "input line mismatch: expected %d instead of %d\n", cnt, in1);  exit(-1);}
  }
  if (cnt != cities) {fprintf(stderr, "read %d instead of %d cities\n", cnt, cities);  exit(-1);}

  fscanf(f, "%s", str);
  if (strcmp(str, "EOF") != 0) {fprintf(stderr, "didn't see 'EOF' at end of file\n");  exit(-1);}

  /*
    Allocate sequential space in GPU memory for our position arrays, we Allocate
    enough space for each city, stored as a float, for each of our x & y coords.
  */
  mallocOnGPU(*posx_d, sizeof(float) * cities);
  mallocOnGPU(*posy_d, sizeof(float) * cities);
  /*
    Copy our coordinate arrays into GPU memory as posx_d and posy_d. We don't
    need to do this in our single threaded app, just need to load into posx and
    posy.
  */
  copyToGPU(*posx_d, posx, sizeof(float) * cities);
  copyToGPU(*posy_d, posy, sizeof(float) * cities);

  fclose(f);
  free(posx);//Don't need to free memory for posx and posy in TSP_CPU.
  free(posy);

  return cities;
}

/******************************************************************************/
/*** main function ************************************************************/
/******************************************************************************/

int main(int argc, char *argv[])
{
  printf("2-opt TSP CUDA GPU code v2.2 [Kepler]\n");
  printf("Copyright (c) 2014, Texas State University. All rights reserved.\n");

  int cities, restarts, climbs, best, threads;
  long long moves;
  int *glob_d;
  float *posx_d, *posy_d, *soln;
  double runtime;
  struct timeval starttime, endtime;

  if (argc != 3) {fprintf(stderr, "\narguments: input_file restart_count\n"); exit(-1);}
  cities = readInput(argv[1], &posx_d, &posy_d);
  restarts = atoi(argv[2]);
  if (restarts < 1) {fprintf(stderr, "restart_count is too small: %d\n", restarts); exit(-1);}

  printf("configuration: %d cities, %d restarts, %s input\n", cities, restarts, argv[1]);

  cudaFuncSetCacheConfig(TwoOpt, cudaFuncCachePreferEqual);

  if (100 > cities) {
    fprintf(stderr, "the problem size is too small for this version of the code\n");
  } else {
    threads = best_thread_count(cities);
    //glob_d is globally shared memory between all threads (i think?)
    mallocOnGPU(glob_d, 4 * restarts * ((3 * cities + 2 + 31) / 32 * 32));

    gettimeofday(&starttime, NULL);
    Init<<<1, 1>>>();
    /*
      Call to TwoOpt, the function TwoOpt is called a kernel in CUDA. It creates
      a grid containing blocks of threads, with each block containing a number
      of threads. The <<<...>>> notation here is the execution configuration.
      Parameters for it are <<<NumberOfBlocks, NumberOfThreadsPerBlock,
                               AmountOfMemSharedBtwnThreads>>>
      For the parameters in the function call, _d stands for device, i.e. the
      GPU device for the computer. The _d suffix for variables differentiates
      variables that are stored in regular memory vs those stored in GPU memory.
    */
    TwoOpt<<<restarts, threads, sizeof(int) * threads>>>(cities, posx_d, posy_d, glob_d);
    CudaTest("kernel launch failed");  // needed for timing
    gettimeofday(&endtime, NULL);

    /*
      After running algorithm on all threads, we get
    */
    copyFromGPUSymbol(&climbs, climbs_d, sizeof(int));
    copyFromGPUSymbol(&best, best_d, sizeof(int));
    copyFromGPUSymbol(&soln, soln_d, sizeof(void *));
    float *pos = (float *)malloc(sizeof(float) * (cities + 1) * 2);  if (pos == NULL) {fprintf(stderr, "cannot allocate pos\n");  exit(-1);}
    copyFromGPU(pos, soln, sizeof(float) * (cities + 1) * 2);

    runtime = endtime.tv_sec + endtime.tv_usec / 1000000.0 - starttime.tv_sec - starttime.tv_usec / 1000000.0;
    moves = 1LL * climbs * (cities - 2) * (cities - 1) / 2;

    printf("runtime = %.4f s, %.3f Gmoves/s\n", runtime, moves * 0.000000001 / runtime);
    printf("best found tour length = %d\n", best);
    if (1) {  // print best found solution
      for (int i = 0; i < cities; i++) {
        printf("%.1f %.1f\n", pos[i], pos[i + cities + 1]);
      }
    }

    fflush(stdout);
    cudaFree(glob_d);
  }

  cudaFree(posx_d);
  cudaFree(posy_d);
  return 0;
}
