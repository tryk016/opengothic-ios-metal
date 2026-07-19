#include "graphics/iosframeinput.h"
#include "graphics/iosrenderworld.h"
#include "graphics/iosscenesnapshot.h"

#include <array>
#include <cassert>
#include <limits>
#include <stdexcept>
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

struct SceneHandles final {
  IOSRenderEntityId entity;
  IOSMeshHandle     mesh;
  IOSMaterialHandle material;
  IOSTextureHandle  texture;
  IOSLightHandle    light;
  IOSParticleHandle particle;
  };

SceneHandles resolveScene(IOSRenderWorld& world, uint64_t keyBase) {
  return {
    world.resolveEntity(keyBase+1u),
    world.resolveMesh(keyBase+2u),
    world.resolveMaterial(keyBase+3u),
    world.resolveTexture(keyBase+4u),
    world.resolveLight(keyBase+5u),
    world.resolveParticle(keyBase+6u),
    };
  }

IOSSceneFrameState populatedFrame(const SceneHandles& handles,
                                  float cameraX, float objectX) {
  auto frame = frameState(cameraX);
  frame.featureMask |= IOSSceneFeatureLights |
                       IOSSceneFeatureParticles;

  IOSMaterial material;
  material.id               = handles.material;
  material.baseColorTexture = handles.texture;
  frame.materials.push_back(material);

  IOSRenderEntityState entity;
  entity.id       = handles.entity;
  entity.mesh     = handles.mesh;
  entity.material = handles.material;
  entity.transform.set(0u,3u,objectX);
  entity.bounds.minimum = {-1.f,-2.f,-3.f};
  entity.bounds.maximum = { 1.f, 2.f, 3.f};
  entity.visibilityMask = IOSSceneVisibilityMain |
                          IOSSceneVisibilityShadow;
  frame.entities.push_back(entity);

  IOSLight light;
  light.id = handles.light;
  frame.lights.push_back(light);

  IOSParticleState particle;
  particle.id       = handles.particle;
  particle.texture  = handles.texture;
  particle.position = {objectX,0.f,0.f};
  particle.size     = {1.f,1.f};
  frame.particles.push_back(particle);
  return frame;
  }

void addDeformation(IOSSceneFrameState& frame,
                    float boneValue, float morphValue) {
  IOSMatrix4x4 bone;
  bone.set(0u,0u,boneValue);
  frame.bones.push_back(bone);
  frame.morphWeights.push_back(morphValue);
  frame.entities[0].boneRange  = {0u,1u};
  frame.entities[0].morphRange = {0u,1u};
  }

template<class Function>
bool rejectsFrame(Function&& function) {
  try {
    function();
    }
  catch(const std::invalid_argument&) {
    return true;
    }
  return false;
  }

}

int main() {
  static_assert(!std::is_copy_constructible_v<IOSFrameInput>);
  static_assert(std::is_nothrow_move_constructible_v<IOSFrameInput>);
  static_assert(std::is_nothrow_move_assignable_v<IOSFrameInput>);
  static_assert(!std::is_copy_constructible_v<IOSRenderWorld>);
  static_assert(!std::is_move_constructible_v<IOSRenderWorld>);

  IOSMatrix4x4 matrixLayout;
  for(std::size_t row=0; row<4u; ++row) {
    for(std::size_t column=0; column<4u; ++column)
      matrixLayout.set(row,column,float(row*4u+column+1u));
    }
  const std::array<float,16> expectedColumnMajor = {
    1.f,5.f,9.f,13.f,
    2.f,6.f,10.f,14.f,
    3.f,7.f,11.f,15.f,
    4.f,8.f,12.f,16.f,
    };
  assert(matrixLayout.elements==expectedColumnMajor);
  assert(matrixLayout.at(0u,3u)==4.f);
  assert(matrixLayout.at(3u,0u)==13.f);

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

  IOSRenderWorld populatedWorld;
  const auto handles = resolveScene(populatedWorld,1000u);
  assert(handles.entity==populatedWorld.resolveEntity(1001u));
  assert(handles.mesh==populatedWorld.resolveMesh(1002u));
  assert(handles.material==populatedWorld.resolveMaterial(1003u));
  assert(handles.texture==populatedWorld.resolveTexture(1004u));
  assert(handles.light==populatedWorld.resolveLight(1005u));
  assert(handles.particle==populatedWorld.resolveParticle(1006u));

  const auto populatedFirst =
    populatedWorld.buildSnapshot(populatedFrame(handles,10.f,1.f));
  assert(populatedFirst->isStructurallyValid());
  assert(populatedFirst->entities.size()==1u);
  assert(populatedFirst->materials.size()==1u);
  assert(populatedFirst->lights.size()==1u);
  assert(populatedFirst->particles.size()==1u);
  assert(populatedWorld.commitAccepted(populatedFirst));

  const auto populatedCanceled =
    populatedWorld.buildSnapshot(populatedFrame(handles,20.f,2.f));
  assert(populatedCanceled->historyValid);
  assert(populatedCanceled->entities[0].previousTransform.at(0u,3u)==1.f);
  assert(populatedCanceled->particles[0].previousPosition.x==1.f);

  const auto populatedAccepted =
    populatedWorld.buildSnapshot(populatedFrame(handles,30.f,3.f));
  assert(populatedAccepted->historyValid);
  assert(populatedAccepted->previousCamera.position.x==10.f);
  assert(populatedAccepted->entities[0].previousTransform.at(0u,3u)==1.f);
  assert(populatedAccepted->particles[0].previousPosition.x==1.f);
  assert(!populatedWorld.acceptsForSubmit(populatedCanceled));
  assert(populatedWorld.commitAccepted(populatedAccepted));

  auto deformationA = populatedFrame(handles,40.f,4.f);
  addDeformation(deformationA,2.f,0.25f);
  const auto acceptedDeformationA =
    populatedWorld.buildSnapshot(std::move(deformationA));
  assert(populatedWorld.commitAccepted(acceptedDeformationA));

  auto changedMeshHandles = handles;
  changedMeshHandles.mesh = populatedWorld.resolveMesh(1010u);
  auto deformationB = populatedFrame(changedMeshHandles,50.f,5.f);
  addDeformation(deformationB,3.f,0.5f);
  const auto changedMesh =
    populatedWorld.buildSnapshot(std::move(deformationB));
  assert(changedMesh->historyValid);
  assert(changedMesh->currentBones==changedMesh->previousBones);
  assert(changedMesh->currentMorphWeights==changedMesh->previousMorphWeights);
  assert(populatedWorld.commitAccepted(changedMesh));

  auto deformationC = populatedFrame(changedMeshHandles,60.f,6.f);
  addDeformation(deformationC,4.f,0.75f);
  const auto matchingMesh =
    populatedWorld.buildSnapshot(std::move(deformationC));
  assert(matchingMesh->historyValid);
  assert(matchingMesh->previousBones[0].at(0u,0u)==3.f);
  assert(matchingMesh->previousMorphWeights[0]==0.5f);

  IOSRenderWorld invalidWorld;
  const auto invalidHandles = resolveScene(invalidWorld,2000u);

  auto fabricatedMesh = populatedFrame(invalidHandles,1.f,1.f);
  fabricatedMesh.entities[0].mesh = {
    invalidWorld.generation(),
    invalidHandles.mesh.value+1000u,
    };
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(fabricatedMesh));
    }));

  auto missingMaterial = populatedFrame(invalidHandles,1.f,1.f);
  missingMaterial.materials.clear();
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(missingMaterial));
    }));

  auto duplicateMaterial = populatedFrame(invalidHandles,1.f,1.f);
  duplicateMaterial.materials.push_back(duplicateMaterial.materials.front());
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(duplicateMaterial));
    }));

  auto unknownFeature = populatedFrame(invalidHandles,1.f,1.f);
  unknownFeature.featureMask |= uint64_t(1) << 63u;
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(unknownFeature));
    }));

  auto nonFinite = populatedFrame(invalidHandles,1.f,1.f);
  nonFinite.camera.position.x = std::numeric_limits<float>::quiet_NaN();
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(nonFinite));
    }));

  auto foreignTexture = populatedFrame(invalidHandles,1.f,1.f);
  foreignTexture.materials[0].baseColorTexture =
    secondWorld.resolveTexture(3000u);
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(foreignTexture));
    }));

  auto fabricatedTexture = populatedFrame(invalidHandles,1.f,1.f);
  fabricatedTexture.materials[0].baseColorTexture = {
    invalidWorld.generation(),
    invalidHandles.texture.value+1000u,
    };
  assert(rejectsFrame([&]() {
    (void)invalidWorld.buildSnapshot(std::move(fabricatedTexture));
    }));

  const auto firstValidAfterRejects =
    invalidWorld.buildSnapshot(populatedFrame(invalidHandles,1.f,1.f));
  assert(firstValidAfterRejects->sequence.value==1u);
  assert(firstValidAfterRejects->isStructurallyValid());

  IOSRenderWorld optionalTextureWorld;
  const auto optionalHandles = resolveScene(optionalTextureWorld,4000u);
  auto optionalTextureFrame = populatedFrame(optionalHandles,1.f,1.f);
  optionalTextureFrame.materials[0].baseColorTexture = {};
  optionalTextureFrame.particles[0].texture = {};
  const auto optionalTextureSnapshot =
      optionalTextureWorld.buildSnapshot(std::move(optionalTextureFrame));
  assert(optionalTextureSnapshot->isStructurallyValid());

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

  auto staleFrame = frameState(5.f);
  IOSMaterial staleMaterial;
  staleMaterial.id = {oldGeneration,1u};
  staleFrame.materials.push_back(staleMaterial);
  IOSRenderEntityState staleEntity;
  staleEntity.id       = oldEntity;
  staleEntity.mesh     = {oldGeneration,1u};
  staleEntity.material = staleMaterial.id;
  staleFrame.entities.push_back(staleEntity);
  assert(rejectsFrame([&]() {
    (void)world.buildSnapshot(std::move(staleFrame));
    }));

  const auto newWorldFirst = world.buildSnapshot(frameState(5.f));
  assert(newWorldFirst->sequence.value==1u);
  assert(!newWorldFirst->historyValid);
  return 0;
  }
