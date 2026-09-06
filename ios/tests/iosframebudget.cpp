#include "graphics/iosframebudget.h"

#include <cassert>

int main() {
  IOSFrameBudget budget;
  assert(budget.effectiveFps(0)==0);
  budget.update(25,0,60,false);
  budget.update(2,2,60,false);
  assert(budget.fpsLimit==0); // A transient spike does not change cadence.
  for(int i=0;i<3;++i) budget.update(25,0,60,false);
  assert(budget.effectiveFps(60)==30);
  for(int i=0;i<29;++i) budget.update(2,2,60,false);
  assert(budget.effectiveFps(60)==30);
  budget.update(2,2,60,false);
  assert(budget.effectiveFps(60)==60);

  budget = {};
  for(int i=0;i<3;++i) budget.update(2,2,0,true);
  assert(budget.effectiveFps(0)==60);
  for(int i=0;i<4;++i) budget.update(2,2,0,true);
  assert(budget.effectiveFps(0)==60); // Cooldown between changes.
  budget.update(2,2,0,true);
  assert(budget.effectiveFps(0)==30);
  for(int i=0;i<30;++i) budget.update(2,2,0,false);
  assert(budget.effectiveFps(0)==60);
  for(int i=0;i<30;++i) budget.update(2,2,0,false);
  assert(budget.effectiveFps(0)==0);

  budget = {};
  for(int i=0;i<60;++i) budget.update(100,100,30,true);
  assert(budget.effectiveFps(30)==30); // Honor the user's lower cap.
  }
