#pragma once

#include <Tempest/Matrix4x4>
#include <Tempest/Point>

#include <cstdint>
#include <stdexcept>

class Material;
class StaticMesh;

enum class IOSSceneSourceKind : uint8_t {
  Landscape,
  Static,
  Movable,
  Animated,
  Particle,
  Morph,
  };

struct IOSSceneSource final {
  IOSSceneSourceKind kind = IOSSceneSourceKind::Landscape;
  // Stable for one live source object. A recycled VisualObjects slot receives
  // a fresh non-zero value and never inherits the previous object's identity.
  uint64_t           sourceId = 0;

  const StaticMesh*  mesh = nullptr;
  const Material*    material = nullptr;

  Tempest::Matrix4x4 transform;
  Tempest::Vec3      localBoundsMin;
  Tempest::Vec3      localBoundsMax;
  bool               hasLocalBounds = false;

  // Element offsets into StaticMesh::ibo; never byte offsets.
  uint32_t           firstIndex = 0;
  uint32_t           indexCount = 0;
  };

// The visitor is a direct function pointer so walking the live source set does
// not allocate. Pointers in IOSSceneSource are borrowed for the callback; the
// extractor must resolve/copy what it needs before returning.
using IOSSceneSourceVisitor = void (*)(void* context, const IOSSceneSource& source);

// A synchronous, non-owning source enumerator. RendererIOS consumes the
// provider during the buildSceneSnapshot call and never retains sourceContext
// or any pointers yielded to the visitor.
using IOSSceneSourceEnumerator = void (*)(
    const void* sourceContext,
    void* visitorContext,
    IOSSceneSourceVisitor visitor);

struct IOSSceneSourceProvider final {
  const void*              sourceContext = nullptr;
  IOSSceneSourceEnumerator enumerate     = nullptr;

  constexpr explicit operator bool() const noexcept {
    return sourceContext!=nullptr && enumerate!=nullptr;
    }

  void visit(void* visitorContext, IOSSceneSourceVisitor visitor) const {
    if(bool(*this) && visitor!=nullptr)
      enumerate(sourceContext,visitorContext,visitor);
    }
  };

class IOSSceneSourceIdentityAllocator final {
  public:
    [[nodiscard]]
    uint64_t assign(uint64_t& slotIdentity) {
      if(slotIdentity!=0)
        throw std::logic_error(
            "RendererIOS source identity assigned to a live slot");
      if(nextIdentity==0)
        throw std::overflow_error(
            "RendererIOS exhausted scene source identities");
      slotIdentity = nextIdentity++;
      return slotIdentity;
      }

    void release(uint64_t& slotIdentity) noexcept {
      slotIdentity = 0;
      }

  private:
    uint64_t nextIdentity = 1;
  };

inline void emitIOSSceneSource(void* context,
                               IOSSceneSourceVisitor visitor,
                               const IOSSceneSource& source) {
  if(visitor!=nullptr && source.sourceId!=0)
    visitor(context,source);
  }
