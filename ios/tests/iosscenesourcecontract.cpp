#include "graphics/iosscenesource.h"
#include "graphics/mesh/submesh/staticmesh.h"
#include "graphics/worldview.h"

#include <cassert>
#include <limits>
#include <type_traits>
#include <vector>

namespace {

struct VisitState {
  uint64_t sourceId = 0;
  uint32_t visits = 0;
  };

void collectSource(void* context, const IOSSceneSource& source) {
  auto& state = *static_cast<VisitState*>(context);
  state.sourceId = source.sourceId;
  ++state.visits;
  }

void enumerateOneSource(const void* sourceContext,
                        void* visitorContext,
                        IOSSceneSourceVisitor visitor) {
  const auto& source = *static_cast<const IOSSceneSource*>(sourceContext);
  emitIOSSceneSource(visitorContext,visitor,source);
  }

Resources::Vertex vertex(float x, float y, float z) {
  Resources::Vertex result = {};
  result.pos[0] = x;
  result.pos[1] = y;
  result.pos[2] = z;
  return result;
  }

}

int main() {
  static_assert(std::is_same_v<
      IOSSceneSourceVisitor,
      void (*)(void*,const IOSSceneSource&)>);
  static_assert(std::is_same_v<
      IOSSceneSourceEnumerator,
      void (*)(const void*,void*,IOSSceneSourceVisitor)>);
  using WorldVisitor = void (WorldView::*)(
      void*,IOSSceneSourceVisitor) const;
  static_assert(std::is_same_v<
      decltype(&WorldView::visitIOSSceneSources),
      WorldVisitor>);
  using ItemSourceId = uint64_t (VisualObjects::Item::*)() const noexcept;
  static_assert(std::is_same_v<
      decltype(&VisualObjects::Item::sourceId),
      ItemSourceId>);

  IOSSceneSource source;
  source.kind       = IOSSceneSourceKind::Landscape;
  source.hasLocalBounds = true;
  source.firstIndex = 3;
  source.indexCount = 6;

  IOSSceneSourceIdentityAllocator identities;
  uint64_t slotIdentity = 0;
  const uint64_t firstIdentity = identities.assign(slotIdentity);
  assert(firstIdentity!=0);
  assert(slotIdentity==firstIdentity);
  assert(slotIdentity==firstIdentity); // Stable for the live slot.

  VisitState state;
  IOSSceneSourceVisitor visitor = &collectSource;
  source.sourceId = slotIdentity;
  emitIOSSceneSource(&state,visitor,source);
  assert(state.sourceId==firstIdentity);
  assert(state.visits==1);
  emitIOSSceneSource(&state,nullptr,source);
  assert(state.visits==1);

  identities.release(slotIdentity);
  source.sourceId = slotIdentity;
  emitIOSSceneSource(&state,visitor,source);
  assert(state.visits==1);

  const uint64_t recycledIdentity = identities.assign(slotIdentity);
  assert(recycledIdentity!=0);
  assert(recycledIdentity!=firstIdentity);
  source.sourceId = recycledIdentity;
  emitIOSSceneSource(&state,visitor,source);
  assert(state.sourceId==recycledIdentity);
  assert(state.visits==2);

  const IOSSceneSourceProvider provider = {
    &source,
    &enumerateOneSource,
    };
  provider.visit(&state,visitor);
  assert(state.sourceId==recycledIdentity);
  assert(state.visits==3);
  IOSSceneSourceProvider().visit(&state,visitor);
  provider.visit(&state,nullptr);
  assert(state.visits==3);

  const std::vector<Resources::Vertex> vertices = {
    vertex(-2.f, 1.f,  4.f),
    vertex( 3.f,-5.f,  2.f),
    vertex( 1.f, 6.f, -7.f),
    vertex(99.f,99.f, 99.f),
    vertex( 8.f, 7.f,  6.f),
    vertex( 9.f,10.f, 11.f),
    };
  const std::vector<uint32_t> indices = {
    0,1,2,
    3,3,3, // A legal source degenerate must remain part of generic bounds.
    1,4,5,
    };

  Bounds bounds;
  assert(StaticMesh::computeSubMeshBounds(bounds,vertices,indices,0,6));
  assert(bounds.bbox[0].x==-2.f);
  assert(bounds.bbox[0].y==-5.f);
  assert(bounds.bbox[0].z==-7.f);
  assert(bounds.bbox[1].x==99.f);
  assert(bounds.bbox[1].y==99.f);
  assert(bounds.bbox[1].z==99.f);

  assert(StaticMesh::computeSubMeshBounds(bounds,vertices,indices,6,3));
  assert(bounds.bbox[0].x==3.f);
  assert(bounds.bbox[0].y==-5.f);
  assert(bounds.bbox[0].z==2.f);
  assert(bounds.bbox[1].x==9.f);
  assert(bounds.bbox[1].y==10.f);
  assert(bounds.bbox[1].z==11.f);

  assert(!StaticMesh::computeSubMeshBounds(bounds,vertices,indices,8,3));
  assert(!StaticMesh::computeSubMeshBounds(
      bounds,vertices,indices,std::numeric_limits<size_t>::max(),3));
  assert(!StaticMesh::computeSubMeshBounds(bounds,vertices,indices,0,5));

  const std::vector<uint32_t> invalidIndex = {0,1,99};
  assert(!StaticMesh::computeSubMeshBounds(bounds,vertices,invalidIndex,0,3));

  auto nonFinite = vertices;
  nonFinite[0].pos[0] = std::numeric_limits<float>::infinity();
  assert(!StaticMesh::computeSubMeshBounds(bounds,nonFinite,indices,0,3));

  std::vector<uint32_t> packedIndices(
      size_t(PackedMesh::MaxInd),uint32_t(3));
  packedIndices[0] = 0;
  packedIndices[1] = 1;
  packedIndices[2] = 2;
  std::vector<uint8_t> packedIndices8(
      size_t(PackedMesh::MaxPrim)*4u,uint8_t(0));
  const size_t metadata = packedIndices8.size()-4u;
  packedIndices8[metadata+0u] = 0;
  packedIndices8[metadata+1u] = 0;
  packedIndices8[metadata+2u] = 1; // One real primitive.
  packedIndices8[metadata+3u] = 3; // Three real vertices: metadata marker.

  assert(StaticMesh::computePackedSubMeshBounds(
      bounds,vertices,packedIndices,packedIndices8,
      0,size_t(PackedMesh::MaxInd)));
  assert(bounds.bbox[0].x==-2.f);
  assert(bounds.bbox[0].y==-5.f);
  assert(bounds.bbox[0].z==-7.f);
  assert(bounds.bbox[1].x==3.f);
  assert(bounds.bbox[1].y==6.f);
  assert(bounds.bbox[1].z==4.f);

  packedIndices8[metadata+3u] = 0;
  assert(StaticMesh::computePackedSubMeshBounds(
      bounds,vertices,packedIndices,packedIndices8,
      0,size_t(PackedMesh::MaxInd)));
  assert(bounds.bbox[1].x==99.f);
  assert(bounds.bbox[1].y==99.f);
  assert(bounds.bbox[1].z==99.f);
  }
