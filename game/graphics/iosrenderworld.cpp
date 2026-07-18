#include "iosrenderworld.h"

#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace {

std::atomic_uint64_t NextWorldGeneration{1};

static_assert(std::is_nothrow_copy_assignable_v<IOSSceneSnapshotPtr>);

uint64_t nextNonZero(uint64_t& value) noexcept {
  uint64_t result = value++;
  if(result==0)
    result = value++;
  return result;
  }

void advanceNonZero(uint64_t& value) noexcept {
  ++value;
  if(value==0)
    ++value;
  }

template<class Handle>
Handle resolveStableHandle(std::unordered_map<uint64_t,Handle>& registry,
                           uint64_t stableKey,
                           IOSWorldGeneration generation,
                           uint64_t& nextId) {
  if(stableKey==0)
    throw std::invalid_argument("RendererIOS stable scene key must be non-zero");
  if(const auto found=registry.find(stableKey); found!=registry.end())
    return found->second;
  const Handle handle = {generation,nextNonZero(nextId)};
  registry.emplace(stableKey,handle);
  return handle;
  }

bool compatibleRange(IOSIndexRange current, IOSIndexRange previous,
                     std::size_t currentSize, std::size_t previousSize) noexcept {
  const std::size_t currentOffset  = std::size_t(current.offset);
  const std::size_t previousOffset = std::size_t(previous.offset);
  const std::size_t count          = std::size_t(current.count);
  return current.count==previous.count &&
         currentOffset<=currentSize && count<=currentSize-currentOffset &&
         previousOffset<=previousSize && count<=previousSize-previousOffset;
  }

}

IOSRenderWorld::IOSRenderWorld()
  : worldGeneration(allocateGeneration()) {
  }

IOSWorldGeneration IOSRenderWorld::generation() const noexcept {
  return worldGeneration;
  }

IOSRenderEntityId IOSRenderWorld::resolveEntity(uint64_t stableKey) {
  return resolveStableHandle(entityRegistry,stableKey,worldGeneration,nextEntityId);
  }

IOSMeshHandle IOSRenderWorld::resolveMesh(uint64_t stableKey) {
  return resolveStableHandle(meshRegistry,stableKey,worldGeneration,nextMeshId);
  }

IOSMaterialHandle IOSRenderWorld::resolveMaterial(uint64_t stableKey) {
  return resolveStableHandle(materialRegistry,stableKey,worldGeneration,nextMaterialId);
  }

IOSSceneSnapshotPtr IOSRenderWorld::buildSnapshot(IOSSceneFrameState&& frame) {
  auto snapshot = std::make_shared<IOSSceneSnapshot>();
  snapshot->generation          = worldGeneration;
  snapshot->sequence            = nextSequence;
  snapshot->currentCamera       = frame.camera;
  snapshot->previousCamera      = frame.camera;
  snapshot->currentSky          = frame.sky;
  snapshot->previousSky         = frame.sky;
  snapshot->materials           = std::move(frame.materials);
  snapshot->lights              = std::move(frame.lights);
  snapshot->currentBones        = std::move(frame.bones);
  snapshot->previousBones       = snapshot->currentBones;
  snapshot->currentMorphWeights = std::move(frame.morphWeights);
  snapshot->previousMorphWeights = snapshot->currentMorphWeights;
  snapshot->effects             = std::move(frame.effects);
  snapshot->featureMask         = frame.featureMask;

  snapshot->entities.reserve(frame.entities.size());
  for(auto& entity:frame.entities) {
    snapshot->entities.push_back({
      entity.id,
      entity.mesh,
      entity.material,
      entity.transform,
      entity.transform,
      entity.bounds,
      entity.boneRange,
      entity.morphRange,
      entity.visibilityMask,
      });
    }

  snapshot->particles.reserve(frame.particles.size());
  for(auto& particle:frame.particles) {
    snapshot->particles.push_back({
      particle.id,
      particle.position,
      particle.position,
      particle.velocity,
      particle.color,
      particle.size,
      particle.rotation,
      particle.texture,
      });
    }

  const auto byId = [](const auto& lhs, const auto& rhs) {
    return lhs.id.value<rhs.id.value;
    };
  std::sort(snapshot->entities.begin(),snapshot->entities.end(),byId);
  std::sort(snapshot->materials.begin(),snapshot->materials.end(),byId);
  std::sort(snapshot->lights.begin(),snapshot->lights.end(),byId);
  std::sort(snapshot->particles.begin(),snapshot->particles.end(),byId);

  const bool viewportCompatible =
    committedSnapshot!=nullptr &&
    committedSnapshot->currentCamera.viewport==snapshot->currentCamera.viewport;
  const bool historyAvailable =
    !frame.resetHistory && viewportCompatible &&
    committedSnapshot->generation==worldGeneration;
  if(historyAvailable) {
    snapshot->historyValid  = true;
    snapshot->previousCamera = committedSnapshot->currentCamera;
    snapshot->previousSky    = committedSnapshot->currentSky;

    std::size_t previousEntity = 0;
    for(auto& entity:snapshot->entities) {
      while(previousEntity<committedSnapshot->entities.size() &&
            committedSnapshot->entities[previousEntity].id.value<entity.id.value)
        ++previousEntity;
      if(previousEntity>=committedSnapshot->entities.size() ||
         committedSnapshot->entities[previousEntity].id!=entity.id)
        continue;
      const auto& previous = committedSnapshot->entities[previousEntity];
      entity.previousTransform = previous.currentTransform;

      if(compatibleRange(entity.boneRange,previous.boneRange,
                         snapshot->previousBones.size(),
                         committedSnapshot->currentBones.size())) {
        const auto src = committedSnapshot->currentBones.begin()+
                         std::ptrdiff_t(previous.boneRange.offset);
        const auto dst = snapshot->previousBones.begin()+
                         std::ptrdiff_t(entity.boneRange.offset);
        std::copy_n(src,entity.boneRange.count,dst);
        }
      if(compatibleRange(entity.morphRange,previous.morphRange,
                         snapshot->previousMorphWeights.size(),
                         committedSnapshot->currentMorphWeights.size())) {
        const auto src = committedSnapshot->currentMorphWeights.begin()+
                         std::ptrdiff_t(previous.morphRange.offset);
        const auto dst = snapshot->previousMorphWeights.begin()+
                         std::ptrdiff_t(entity.morphRange.offset);
        std::copy_n(src,entity.morphRange.count,dst);
        }
      }

    std::size_t previousParticle = 0;
    for(auto& particle:snapshot->particles) {
      while(previousParticle<committedSnapshot->particles.size() &&
            committedSnapshot->particles[previousParticle].id.value<particle.id.value)
        ++previousParticle;
      if(previousParticle<committedSnapshot->particles.size() &&
         committedSnapshot->particles[previousParticle].id==particle.id)
        particle.previousPosition =
          committedSnapshot->particles[previousParticle].currentPosition;
      }
    }

  if(!snapshot->isStructurallyValid())
    throw std::invalid_argument("RendererIOS scene snapshot failed structural validation");

  snapshot->structurallyValidated = true;
  lastBuiltSequence = snapshot->sequence;
  advanceNonZero(nextSequence.value);
  return snapshot;
  }

bool IOSRenderWorld::acceptsForSubmit(
    const IOSSceneSnapshotPtr& snapshot) const noexcept {
  if(snapshot==nullptr || snapshot->generation!=worldGeneration ||
     !snapshot->sequence || snapshot->sequence!=lastBuiltSequence ||
     !snapshot->structurallyValidated)
    return false;
  if(committedSnapshot!=nullptr &&
     snapshot->sequence.value<=committedSnapshot->sequence.value)
    return false;
  return true;
  }

bool IOSRenderWorld::commitAccepted(const IOSSceneSnapshotPtr& snapshot) noexcept {
  if(!acceptsForSubmit(snapshot))
    return false;
  committedSnapshot = snapshot;
  return true;
  }

void IOSRenderWorld::resetHistory() noexcept {
  committedSnapshot.reset();
  lastBuiltSequence = {};
  }

void IOSRenderWorld::resetWorld() noexcept {
  committedSnapshot.reset();
  entityRegistry.clear();
  meshRegistry.clear();
  materialRegistry.clear();
  worldGeneration = allocateGeneration();
  nextSequence     = {1};
  lastBuiltSequence = {};
  }

IOSSceneSequence IOSRenderWorld::lastAcceptedSequence() const noexcept {
  return committedSnapshot!=nullptr ? committedSnapshot->sequence
                                    : IOSSceneSequence{};
  }

IOSWorldGeneration IOSRenderWorld::allocateGeneration() noexcept {
  uint64_t value = NextWorldGeneration.fetch_add(1,std::memory_order_relaxed);
  if(value==0)
    value = NextWorldGeneration.fetch_add(1,std::memory_order_relaxed);
  return {value};
  }
