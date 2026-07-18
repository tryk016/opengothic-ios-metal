#pragma once

#include "iosscenesnapshot.h"

#include <cstdint>
#include <unordered_map>
#include <unordered_set>

class IOSRenderWorld final {
  public:
    IOSRenderWorld();
    IOSRenderWorld(const IOSRenderWorld&) = delete;
    IOSRenderWorld& operator=(const IOSRenderWorld&) = delete;
    IOSRenderWorld(IOSRenderWorld&&) = delete;
    IOSRenderWorld& operator=(IOSRenderWorld&&) = delete;

    IOSWorldGeneration generation() const noexcept;

    IOSRenderEntityId resolveEntity(uint64_t stableKey);
    IOSMeshHandle     resolveMesh(uint64_t stableKey);
    IOSMaterialHandle resolveMaterial(uint64_t stableKey);
    IOSTextureHandle  resolveTexture(uint64_t stableKey);
    IOSLightHandle    resolveLight(uint64_t stableKey);
    IOSParticleHandle resolveParticle(uint64_t stableKey);

    IOSSceneSnapshotPtr buildSnapshot(IOSSceneFrameState&& frame);
    bool acceptsForSubmit(const IOSSceneSnapshotPtr& snapshot) const noexcept;
    bool commitAccepted(const IOSSceneSnapshotPtr& snapshot) noexcept;

    void resetHistory() noexcept;
    void resetWorld() noexcept;

    IOSSceneSequence lastAcceptedSequence() const noexcept;

  private:
    IOSWorldGeneration allocateGeneration() noexcept;

    IOSWorldGeneration worldGeneration;
    IOSSceneSequence   nextSequence = {1};
    IOSSceneSequence   lastBuiltSequence;
    IOSSceneSnapshotPtr committedSnapshot;

    uint64_t nextEntityId   = 1;
    uint64_t nextMeshId     = 1;
    uint64_t nextMaterialId = 1;
    uint64_t nextTextureId  = 1;
    uint64_t nextLightId    = 1;
    uint64_t nextParticleId = 1;

    std::unordered_map<uint64_t,IOSRenderEntityId> entityRegistry;
    std::unordered_map<uint64_t,IOSMeshHandle>     meshRegistry;
    std::unordered_map<uint64_t,IOSMaterialHandle> materialRegistry;
    std::unordered_map<uint64_t,IOSTextureHandle>  textureRegistry;
    std::unordered_map<uint64_t,IOSLightHandle>    lightRegistry;
    std::unordered_map<uint64_t,IOSParticleHandle> particleRegistry;

    std::unordered_set<uint64_t> issuedEntityIds;
    std::unordered_set<uint64_t> issuedMeshIds;
    std::unordered_set<uint64_t> issuedMaterialIds;
    std::unordered_set<uint64_t> issuedTextureIds;
    std::unordered_set<uint64_t> issuedLightIds;
    std::unordered_set<uint64_t> issuedParticleIds;
  };
