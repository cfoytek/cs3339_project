/*
  Produced for Vikas Chaudary's Computer Architecture Class

  This program is a single threaded random restart hill climbing Travelling
  Salesman Problem solver with 2-opt local search heuristic. This program
  is heavily based on TSP_GPU.cu, authored by Molly O'Neil and Martin Burtscher,
  and is intended to be a fair-comparison-test between multithreaded and single-
  threaded TSP solvers using this algorithm. For more information about
  TSP_GPU.cu, visit http://cs.txstate.edu/~burtscher/research/TSP_GPU/.
*/

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
#include <sys/time.h>

/////////////////////////////////////////////////////////////
//  readInput takes as input the name of the input file,   //
//  and a pointer to *posx and *posy, and returns the      //
//  number of cities read from the input file.             //
/////////////////////////////////////////////////////////////
static int readInput(char *fname, float **posx, float **posy) {
  //TODO: read input from file to coordinate arrays
}

int main(int argc, char *argv[]) {
  printf("2-opt TSP CPU based single threaded solver\n\n");

  int cities, restarts, climbs, best;
  long long moves;
  float *posx, *posy;
  double runtime;
  struct timeval starttime, endtime;

  //Read in command line parameters, initialize position arrays with readInput
  if (argc != 3) {fprintf(stderr, "\narguments: input_file restart_count\n"); exit(-1);}
  //cities = readInput(argv[1], &posx, &posy);
  restarts = atoi(argv[2]);
  if (restarts < 1) {fprintf(stderr, "restart_count is too small: %d\n", restarts); exit(-1);}

    printf("configuration: %d cities, %d restarts, %s input\n", cities, restarts, argv[1]);
}
