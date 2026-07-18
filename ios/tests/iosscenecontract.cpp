#include "graphics/iosframeinput.h"
#include "graphics/iosrenderworld.h"
#include "graphics/iosscenesnapshot.h"

#include <cassert>
#include <type_traits>
#include <utility>

namespace {

IOSSceneFrameState frameState(float cameraX) {
  IOSSceneFrameState frame;
  frame.camera.position        = {cameraX,2.f,3.f};
  frame.camera.viewport.width  = 1280u;
  frame.camera.viewport.height = 720u;
  frame.camera.nearPlane       = 0.1f;
  frame.camera.farPlane        = 1000.f;
  frame.featureMask = IOSSceneFeatureReactiveMask |
                      IOSSceneFeatureTranslucentMask;
  return frame;
  }

}

int main() {
  static_assert(!std::is_copy_constructible_v<IOSFrameInput>);
  static_assert(std::is_nothrow_move_constructible_v<IOSFrameInput>);
  static_assert(std::is_nothrow_move_assignable_v<IOSFrameInput>);
  static_assert(!std::is_copy_constructible_v<IOSRenderWorld>);
  static_assert(!std::is_move_constructible_v<IOSRenderWorld>);

  IOSRenderWorld world;
  IOSRenderWorld secondWorld;
  assert(world.generation());
  assert(secondWorld.generation());
  assert(world.generation()!=secondWorld.generation());

  const auto first = world.buildSnapshot(frameState(1.f));
  assert(first->generation==world.generation());
  assert(first->sequence.value==1u);
  assert(!first->historyValid);
  assert(first->currentCamera==first->previousCamera);
  assert(first->isStructurallyValid());
  assert(first->featureMask==(IOSSceneFeatureReactiveMask |
                              IOSSceneFeatureTranslucentMask));
  assert(world.acceptsForSubmit(first));
  assert(world.commitAccepted(first));

  const auto canceled = world.buildSnapshot(frameState(2.f));
  assert(canceled->sequence.value==2u);
  assert(canceled->historyValid);
  assert(world.acceptsForSubmit(canceled));

  const auto accepted = world.buildSnapshot(frameState(3.f));
  assert(accepted->sequence.value==3u);
  assert(accepted->historyValid);
  assert(accepted->previousCamera.position.x==1.f);
  assert(!world.acceptsForSubmit(canceled));
  assert(world.acceptsForSubmit(accepted));
  assert(world.commitAccepted(accepted));
  assert(!world.commitAccepted(canceled));
  assert(world.lastAcceptedSequence()==accepted->sequence);

  world.resetHistory();
  assert(!world.acceptsForSubmit(accepted));
  assert(!world.acceptsForSubmit(canceled));
  const auto resetHistory = world.buildSnapshot(frameState(4.f));
  assert(!resetHistory->historyValid);

  const auto oldGeneration = world.generation();
  const auto oldEntity     = world.resolveEntity(101u);
  assert(oldEntity==world.resolveEntity(101u));
  world.resetWorld();
  assert(world.generation()!=oldGeneration);
  assert(!world.lastAcceptedSequence());
  const auto newEntity = world.resolveEntity(101u);
  assert(newEntity.generation==world.generation());
  assert(newEntity.generation!=oldEntity.generation);
  assert(newEntity.value>oldEntity.value);

  const auto newWorldFirst = world.buildSnapshot(frameState(5.f));
  assert(newWorldFirst->sequence.value==1u);
  assert(!newWorldFirst->historyValid);
  return 0;
  }
