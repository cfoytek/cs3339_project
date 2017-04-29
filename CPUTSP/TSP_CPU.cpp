/*
  Produced for Vikas Chaudary's Computer Architecture Class

  This program is a single threaded random restart hill climbing Travelling
  Salesman Problem solver with 2-opt local search heuristic. This program
  is heavily based on TSP_GPU.cu, authored by Molly O'Neil and Martin Burtscher,
  and is intended to be a fair-comparison-test between multithreaded and single-
  threaded TSP solvers using this algorithm. For more information about
  TSP_GPU.cu, visit http://cs.txstate.edu/~burtscher/research/TSP_GPU/.

  The algorithm used for this program is not intended to be efficient in any
  way. It is intended to be a nearly identical copy of the TSP_GPU22.cu program
  for testing purposes. It is not intended for general use in single threaded
  TSP solving.
*/

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
#include <sys/time.h>

#define dist(a, b) round(sqrtf((xcoord[a] - xcoord[b]) * (xcoord[a] - xcoord[b]) + (ycoord[a] - ycoord[b]) * (ycoord[a] - ycoord[b])))
#define swap(a, b) {float tmp = a;  a = b;  b = tmp;}

/////////////////////////////////////////////////////////////
//  readInput takes as input the name of the input file,   //
//  and a pointer to *posx and *posy, and returns the      //
//  number of cities read from the input file.             //
/////////////////////////////////////////////////////////////
static int readInput(char *fname, float **posx, float **posy) {
  //TODO: read input from file to coordinate arrays
}

void TwoOpt(float *posx, float *posy, int cities, int restarts, float *soln, int *climbs) {
  float *xcoord, *ycoord;
  int best = INT_MAX;
  srand(time(NULL)); //Set seed for random number generation

  //Do the inner code iteratively until we've hit our max number of restarts.
  for(int i = 0; i < restarts; i++) {
    //Copy posx and posy to local arrays to do work on them
    for(int i = 0; i < cities; i++) {
      xcoord[i] = posx[i];
      ycoord[i] = posy[i];
    }

    //Randomize our tour
    for(int i = 0; i < cities; i++) {
      int j = rand() % (cities - 1) + 1;
      swap(xcoord[i], xcoord[j]);
      swap(ycoord[i], ycoord[j])
    }
    xcoord[cities] = xcoord[0];
    ycoord[cities] = ycoord[0];

    //After randomizing our tour we find best TwoOpt moves until no better moves
    //are found. If no better moves are found, we've hit a local minimum.
    //  This is the most resource intensive portion of the program. It is O(n^2)
    //at least because the for loops inside of the do-while will iterate through
    //every city (minus 2) j for every city i (minus 2) in the tour. However,
    //this is done iteratively until no better moves are found, so the actual
    //time complexity depends on how close the random starting tour is to a
    //local optimum.
    int minchange;
    int mini = 1;
    int minj = 0;
    do {
      minchange = 0;
      for(int i = 0; i < cities - 2; i++) {//For each city i in the tour
        minchange += dist(i, i + 1);//Calculate the distance between i and i+1
        for(j = i + 2; j < cities; j++) {//Then, loop through each city j > i + 1 in the tour
          int change = dist(i, j) + dist(i + 1, j + 1) - dist(j, j + 1);//And calculate the change if a TwoOpt move were performed
          if(minchange > change) {//If the change that would happen is better than our minimum change
            minchange = change;//Set our minchange to the change that would occur and record the i and j values for swapping
            mini = i;
            minj = j
          }
        }
        minchange -= dist(i, i + 1);//Remove the distance between i and i+1 to get actual change to tour length
      }
      if(minchange < 0) {//If minchange < 0 we've found the best TwoOpt move that will actually improve the tour
        //Perform our TwoOpt move here with min i and min j
        swap(xcoord[mini + 1], xcoord[minj]);
        swap(ycoord[mini + 1], ycoord[minj]);
        //The above should swap the edges from
        //  i->i+1, j->j+1 to
        //  i->j, i+1->j+1
      }
      //After performing our best TwoOpt move for this iteration, loop back and
      //find next best TwoOpt move until there are no more moves that actually
      //improve the tour
    } while(minchange < 0);//Keep looping until no

    //If we've exited the above loop, we've found a local minimum for this restart
    //so we calculate the tour cost and save it as best if it's better than current
    //best tour cost.
    //  This is very resource heavy and much of the time spent
    //finding a solution will likely be spent calculating the tour length.
    //A distance matrix, with all distances between cities calculated upfront
    //would increase efficiency of this part of the program, but would incurr
    //O(n^2) storage requirements to hold cities in memory. This is not a big
    //problem for a CPU implementation since main memory (DRAM) is large, but
    //it is a limiting factor for a GPU implementation which has small shared
    //memory.
    int myCost = 0;
    for(int i = 0; i < cities; i++) {
      myCost += dist(i, i + 1);
    }
    if(myCost < best) {
      best = myCost; //If our tour is better than the prev best, save it
    }
    &climbs++;
  }
  &soln = best; //Set our soln to best so we can get it in main
  free(xcoord);
  free(ycoord);
}

int main(int argc, char *argv[]) {
  //Currently there are no limits on how many restarts the program can perform,
  //but runtime is directly dependent on the number of restarts, so it's
  //probably wise to do a small number and work up to a semi-reasonable number.
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

  gettimeofday(&starttime, NULL);
  TwoOpt(&posx, &posy, cities, restarts, &best, &climbs); //Make call to TwoOpt
  gettimeofday(&endtime, NULL);

  //After execution, calculate runtime, and number of moves performed.
  runtime = endtime.tv_sec + endtime.tv_usec / 1000000.0 - starttime.tv_sec - starttime.tv_usec / 1000000.0;
  moves = 1LL * climbs * (cities - 2) * (cities - 1) / 2;

  //Print results
  printf("runtime = %.4f s, %.3f Gmoves/s\n", runtime, moves * 0.000000001 / runtime);
  printf("best found tour length = %d\n", best);

  //Memory cleanup
  free(posx);
  free(posy);
}
