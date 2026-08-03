#include "graphics/iosframeinput.h"
#include "graphics/iosgpusceneplan.h"
#include "graphics/iosrenderworld.h"
#include "graphics/iossceneextractorplan.h"
#include "graphics/iosscenesnapshot.h"

#include <array>
#include <cassert>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace {

// Exact P2.1c2 compositional fixture, mirrored in iosgpusceneplan.cpp.
constexpr uint64_t MovableSourceId = 0x21C2u;

IOSMatrix4x4 movableT0() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,11.f);
  transform.set(1u,3u,22.f);
  transform.set(2u,3u,33.f);
  return transform;
  }

IOSMatrix4x4 movableT1() {
  IOSMatrix4x4 transform;
  transform.set(0u,3u,44.f);
  transform.set(1u,3u,55.f);
  transform.set(2u,3u,66.f);
  return transform;
  }

IOSSceneOpaqueMeshCandidate movableCandidate(
    const IOSMatrix4x4& transform) {
  IOSSceneOpaqueMeshCandidate source;
  source.sourceId       = MovableSourceId;
  source.kind           = IOSSceneMeshKind::Movable;
  source.hasStaticMesh  = true;
  source.hasMaterial    = true;
  source.hasMappedMaterialCategory = true;
  source.materialCategory = IOSMaterialCategory::Opaque;
  source.hasBaseColorTexture = true;
  source.hasLocalBounds = true;
  source.transform      = transform;
  source.localBounds    = {{-1.f,-2.f,-3.f},{1.f,2.f,3.f}};
  source.indices        = {3u,6u};
  return source;
  }

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
  entity.kind     = IOSSceneMeshKind::Landscape;
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

IOSSceneFrameState movableFrame(const SceneHandles& handles,
                                const IOSSceneOpaqueMeshPlan& plan) {
  auto frame = frameState(0.f);

  IOSMaterial material;
  material.id               = handles.material;
  material.baseColorTexture = handles.texture;
  material.usesFallbackTexture = plan.usesFallbackTexture;
  material.category         = plan.materialCategory;
  frame.materials.push_back(material);

  IOSRenderEntityState entity;
  entity.id             = handles.entity;
  entity.mesh           = handles.mesh;
  entity.material       = handles.material;
  entity.kind           = plan.kind;
  entity.transform      = plan.transform;
  entity.bounds         = plan.localBounds;
  entity.visibilityMask = plan.visibilityMask;
  frame.entities.push_back(entity);
  return frame;
  }

IOSGPUSceneMeshCandidate gpuCandidate(
    const IOSSceneSnapshot& snapshot,
    const IOSSceneOpaqueMeshPlan& plan) {
  IOSGPUSceneMeshCandidate source;
  source.snapshotGeneration = snapshot.generation;
  source.registryGeneration = snapshot.generation;
  source.entity             = snapshot.entities[0];
  source.material           = snapshot.materials[0];
  source.hasMaterial        = true;
  source.hasTexture         = true;
  source.hasNativeTexture   = true;
  source.hasSupportedTextureFormat = true;
  source.hasValidNativeTexture = true;
  source.textureWidth       = 1u;
  source.textureHeight      = 1u;
  source.textureMipCount    = 1u;
  source.hasMesh            = true;
  source.hasNativeVertexBuffer = true;
  source.hasNativeIndexBuffer  = true;
  source.vertexBufferByteSize  = IOSLandscapeVertexStride*3u;
  source.indexBufferByteSize =
      IOSLandscapeIndexStride*
      std::size_t(plan.indices.offset+plan.indices.count);
  source.vertexStride = IOSLandscapeVertexStride;
  source.firstIndex   = plan.indices.offset;
  source.indexCount   = plan.indices.count;
  return source;
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

  IOSRenderWorld frameTextureWorld;
  const auto frameZero = frameTextureWorld.resolveFrameTexture(0x1001u,0u);
  assert(frameZero==frameTextureWorld.resolveFrameTexture(0x1001u,0u));
  const auto frameOne = frameTextureWorld.resolveFrameTexture(0x1001u,1u);
  const auto freshSource =
      frameTextureWorld.resolveFrameTexture(0x1002u,0u);
  assert(frameOne!=frameZero);
  assert(freshSource!=frameZero);
  assert(freshSource!=frameOne);

  // These pairs alias under common lossy XOR, swapping, or 32-bit packing.
  const auto xorA = frameTextureWorld.resolveFrameTexture(1u,2u);
  const auto xorB = frameTextureWorld.resolveFrameTexture(3u,0u);
  const auto swapped = frameTextureWorld.resolveFrameTexture(2u,1u);
  const auto lowSource = frameTextureWorld.resolveFrameTexture(5u,7u);
  const auto highSource = frameTextureWorld.resolveFrameTexture(
      (uint64_t(1u)<<32u) | 5u,7u);
  const auto lowOrdinal = frameTextureWorld.resolveFrameTexture(7u,8u);
  const auto highOrdinal = frameTextureWorld.resolveFrameTexture(
      7u,(uint64_t(1u)<<32u) | 8u);
  assert(xorA!=xorB);
  assert(xorA!=swapped);
  assert(lowSource!=highSource);
  assert(lowOrdinal!=highOrdinal);

  const auto maximumFrameTexture = frameTextureWorld.resolveFrameTexture(
      std::numeric_limits<uint64_t>::max(),
      std::numeric_limits<uint64_t>::max());
  assert(maximumFrameTexture);
  assert(maximumFrameTexture==frameTextureWorld.resolveFrameTexture(
      std::numeric_limits<uint64_t>::max(),
      std::numeric_limits<uint64_t>::max()));

  IOSRenderWorld rejectedFrameTextureWorld;
  const auto beforeRejectedSource =
      rejectedFrameTextureWorld.resolveTexture(1u);
  assert(rejectsFrame([&]() {
    (void)rejectedFrameTextureWorld.resolveFrameTexture(
        0u,std::numeric_limits<uint64_t>::max());
    }));
  const auto afterRejectedSource =
      rejectedFrameTextureWorld.resolveFrameTexture(1u,0u);
  assert(afterRejectedSource.value==beforeRejectedSource.value+1u);

  const auto frameTextureGeneration = frameTextureWorld.generation();
  const auto frameTextureBeforeReset =
      frameTextureWorld.resolveFrameTexture(0x2001u,9u);
  frameTextureWorld.resetWorld();
  assert(frameTextureWorld.generation()!=frameTextureGeneration);
  const auto frameTextureAfterReset =
      frameTextureWorld.resolveFrameTexture(0x2001u,9u);
  assert(frameTextureAfterReset.generation==frameTextureWorld.generation());
  assert(frameTextureAfterReset.generation!=
         frameTextureBeforeReset.generation);
  assert(frameTextureAfterReset.value>frameTextureBeforeReset.value);
  assert(frameTextureAfterReset==
         frameTextureWorld.resolveFrameTexture(0x2001u,9u));

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

  IOSSceneOpaqueMeshPlan movablePlanA;
  IOSSceneOpaqueMeshPlan movablePlanB;
  assert(planIOSOpaqueMeshSource(
           movableCandidate(movableT0()),movablePlanA)==
         IOSSceneSourcePlanResult::Planned);
  assert(planIOSOpaqueMeshSource(
           movableCandidate(movableT1()),movablePlanB)==
         IOSSceneSourcePlanResult::Planned);
  assert(movablePlanA.kind==IOSSceneMeshKind::Movable);
  assert(movablePlanB.kind==IOSSceneMeshKind::Movable);
  assert(movablePlanA.entityStableKey==MovableSourceId);
  assert(movablePlanA.entityStableKey==movablePlanB.entityStableKey);
  assert(movablePlanA.meshStableKey==movablePlanB.meshStableKey);
  assert(movablePlanA.materialStableKey==movablePlanB.materialStableKey);
  assert(movablePlanA.textureStableKey==movablePlanB.textureStableKey);

  IOSRenderWorld movableWorld;
  const SceneHandles movableHandles = {
    movableWorld.resolveEntity(movablePlanA.entityStableKey),
    movableWorld.resolveMesh(movablePlanA.meshStableKey),
    movableWorld.resolveMaterial(movablePlanA.materialStableKey),
    movableWorld.resolveTexture(movablePlanA.textureStableKey),
    {},
    {},
    };
  assert(movableHandles.entity==
         movableWorld.resolveEntity(MovableSourceId));
  const auto movableA =
    movableWorld.buildSnapshot(movableFrame(movableHandles,movablePlanA));
  assert(movableA->entities.size()==1u);
  assert(movableA->entities[0].id==movableHandles.entity);
  assert(movableA->entities[0].kind==IOSSceneMeshKind::Movable);
  assert(movableA->materials[0].category==IOSMaterialCategory::Opaque);
  assert(!movableA->materials[0].usesFallbackTexture);
  assert(movableA->entities[0].currentTransform==movableT0());
  assert(movableWorld.commitAccepted(movableA));

  const auto movableB =
    movableWorld.buildSnapshot(movableFrame(movableHandles,movablePlanB));
  assert(movableB->historyValid);
  assert(movableB->entities.size()==1u);
  assert(movableB->entities[0].id==movableA->entities[0].id);
  assert(movableB->entities[0].kind==IOSSceneMeshKind::Movable);
  assert(movableB->entities[0].currentTransform==movableT1());
  assert(movableB->entities[0].previousTransform==movableT0());

  IOSGPUSceneDrawPlan movableGpuPlan;
  assert(planIOSGPUSceneDraw(
           movableB->currentCamera,
           gpuCandidate(*movableB,movablePlanB),
           movableGpuPlan)==IOSGPUSceneDrawPlanResult::Draw);
  assert(movableGpuPlan.constants.model==movableT1());
  assert(movableGpuPlan.materialCategory==IOSMaterialCategory::Opaque);
  assert(movableGpuPlan.kind==IOSSceneMeshKind::Movable);
  assert(movableGpuPlan.pipeline==IOSGPUScenePipelineSelector::Opaque);
  assert(!movableGpuPlan.usesFallbackTexture);

  auto alphaCandidateA = movableCandidate(movableT0());
  alphaCandidateA.materialCategory = IOSMaterialCategory::AlphaTest;
  auto alphaCandidateB = movableCandidate(movableT1());
  alphaCandidateB.materialCategory = IOSMaterialCategory::AlphaTest;
  IOSSceneOpaqueMeshPlan alphaPlanA;
  IOSSceneOpaqueMeshPlan alphaPlanB;
  assert(planIOSOpaqueMeshSource(alphaCandidateA,alphaPlanA)==
         IOSSceneSourcePlanResult::Planned);
  assert(planIOSOpaqueMeshSource(alphaCandidateB,alphaPlanB)==
         IOSSceneSourcePlanResult::Planned);

  IOSRenderWorld alphaWorld;
  const SceneHandles alphaHandles = {
    alphaWorld.resolveEntity(alphaPlanA.entityStableKey),
    alphaWorld.resolveMesh(alphaPlanA.meshStableKey),
    alphaWorld.resolveMaterial(alphaPlanA.materialStableKey),
    alphaWorld.resolveTexture(alphaPlanA.textureStableKey),
    {},
    {},
    };
  const auto alphaA =
      alphaWorld.buildSnapshot(movableFrame(alphaHandles,alphaPlanA));
  assert(alphaA->isStructurallyValid());
  assert(alphaA->materials[0].category==
         IOSMaterialCategory::AlphaTest);
  assert(alphaA->materials[0].alphaCutoff==0.5f);
  assert(alphaWorld.commitAccepted(alphaA));
  const auto alphaB =
      alphaWorld.buildSnapshot(movableFrame(alphaHandles,alphaPlanB));
  assert(alphaB->historyValid);
  assert(alphaB->entities[0].previousTransform==movableT0());
  assert(alphaB->materials[0].category==
         IOSMaterialCategory::AlphaTest);

  IOSGPUSceneDrawPlan alphaGpuPlan;
  assert(planIOSGPUSceneDraw(
           alphaB->currentCamera,gpuCandidate(*alphaB,alphaPlanB),
           alphaGpuPlan)==IOSGPUSceneDrawPlanResult::Draw);
  assert(alphaGpuPlan.materialCategory==
         IOSMaterialCategory::AlphaTest);
  assert(alphaGpuPlan.kind==IOSSceneMeshKind::Movable);
  assert(alphaGpuPlan.pipeline==
         IOSGPUScenePipelineSelector::AlphaTest);
  assert(!alphaGpuPlan.usesFallbackTexture);

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

  for(const auto kind:{
        IOSSceneMeshKind::Landscape,
        IOSSceneMeshKind::Static,
        IOSSceneMeshKind::Movable}) {
    auto opaque = *firstValidAfterRejects;
    opaque.entities[0].kind = kind;
    assert(opaque.isStructurallyValid());

    auto alpha = opaque;
    alpha.materials[0].category = IOSMaterialCategory::AlphaTest;
    alpha.materials[0].alphaCutoff = 0.5f;
    alpha.materials[0].usesFallbackTexture = false;
    assert(alpha.isStructurallyValid());
    alpha.materials[0].usesFallbackTexture = true;
    assert(!alpha.isStructurallyValid());
    alpha.materials[0].usesFallbackTexture = false;
    alpha.materials[0].baseColorTexture = {};
    assert(!alpha.isStructurallyValid());
    alpha.materials[0].baseColorTexture =
        opaque.materials[0].baseColorTexture;
    alpha.materials[0].alphaCutoff = 0.499f;
    assert(!alpha.isStructurallyValid());
    alpha.materials[0].alphaCutoff = 0.501f;
    assert(!alpha.isStructurallyValid());
    }

  auto fabricatedKindSnapshot = *firstValidAfterRejects;
  fabricatedKindSnapshot.entities[0].kind =
      static_cast<IOSSceneMeshKind>(255u);
  assert(!fabricatedKindSnapshot.isStructurallyValid());
  auto fabricatedCategorySnapshot = *firstValidAfterRejects;
  for(const auto category:{
        IOSMaterialCategory::Transparent,
        IOSMaterialCategory::Additive,
        IOSMaterialCategory::Water,
        static_cast<IOSMaterialCategory>(255u)}) {
    fabricatedCategorySnapshot.materials[0].category = category;
    assert(!fabricatedCategorySnapshot.isStructurallyValid());
    }

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
  staleEntity.kind     = IOSSceneMeshKind::Landscape;
  staleFrame.entities.push_back(staleEntity);
  assert(rejectsFrame([&]() {
    (void)world.buildSnapshot(std::move(staleFrame));
    }));

  const auto newWorldFirst = world.buildSnapshot(frameState(5.f));
  assert(newWorldFirst->sequence.value==1u);
  assert(!newWorldFirst->historyValid);
  return 0;
  }
