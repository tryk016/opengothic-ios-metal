#pragma once

#include <Tempest/VertexBuffer>
#include <Tempest/IndexBuffer>
#include <Tempest/Device>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <utility>
#include <vector>

#include "graphics/material.h"
#include "graphics/bounds.h"
#include "graphics/mesh/submesh/packedmesh.h"

#include "resources.h"

class StaticMesh {
  public:
    using Vertex=Resources::Vertex;

    StaticMesh(const PackedMesh& data);
    StaticMesh(const Material& mat, std::vector<Resources::Vertex> vbo, std::vector<uint32_t> ibo);
    StaticMesh(StaticMesh&&)=default;
    StaticMesh& operator=(StaticMesh&&)=default;

    struct SubMesh {
      Material                       material;
      size_t                         iboOffset = 0;
      size_t                         iboLength = 0;
      std::string                    texName;
      Bounds                         localBounds;
      bool                           hasLocalBounds = false;
      Tempest::AccelerationStructure blas;
      };

    struct Morph {
      std::string            name;
      size_t                 numFrames       = 0;
      size_t                 samplesPerFrame = 0;
      int32_t                layer           = 0;
      uint64_t               tickPerFrame    = 50;
      uint64_t               duration        = 0;

      size_t                 index           = 0;
      };

    struct MorphAnim {
      const std::vector<Morph>*     anim    = nullptr;
      const Tempest::StorageBuffer* index   = nullptr;
      const Tempest::StorageBuffer* samples = nullptr;
      };

    const Tempest::AccelerationStructure* blas(size_t iboOffset, size_t iboLen) const;
    const Bounds* localBounds(size_t iboOffset, size_t iboLen) const noexcept;

    static bool computeSubMeshBounds(Bounds& out,
                                     const std::vector<Vertex>& vertices,
                                     const std::vector<uint32_t>& indices,
                                     size_t iboOffset,
                                     size_t iboLength) noexcept;
    static bool computePackedSubMeshBounds(
        Bounds& out,
        const std::vector<Vertex>& vertices,
        const std::vector<uint32_t>& indices,
        const std::vector<uint8_t>& packedIndices,
        size_t iboOffset,
        size_t iboLength) noexcept;

    Tempest::VertexBuffer<Vertex>   vbo;
    Tempest::IndexBuffer<uint32_t>  ibo;
    Tempest::StorageBuffer          ibo8;
    MorphAnim                       morph;

    std::vector<SubMesh>            sub;
    Bounds                          bbox;
  };

inline bool StaticMesh::computeSubMeshBounds(Bounds& out,
                                             const std::vector<Vertex>& vertices,
                                             const std::vector<uint32_t>& indices,
                                             size_t iboOffset,
                                             size_t iboLength) noexcept {
  out = Bounds();
  if(vertices.empty() || iboLength==0 || iboLength%3!=0)
    return false;
  if(iboOffset>indices.size() || iboLength>indices.size()-iboOffset)
    return false;

  Tempest::Vec3 minimum;
  Tempest::Vec3 maximum;
  bool          initialized = false;
  const size_t  end = iboOffset+iboLength;
  for(size_t i=iboOffset; i<end; i+=3) {
    const uint32_t a = indices[i+0];
    const uint32_t b = indices[i+1];
    const uint32_t c = indices[i+2];
    if(size_t(a)>=vertices.size() ||
       size_t(b)>=vertices.size() ||
       size_t(c)>=vertices.size())
      return false;

    const uint32_t triangle[3] = {a,b,c};
    for(const uint32_t index:triangle) {
      const auto& vertex = vertices[size_t(index)];
      if(!std::isfinite(vertex.pos[0]) ||
         !std::isfinite(vertex.pos[1]) ||
         !std::isfinite(vertex.pos[2]))
        return false;
      const Tempest::Vec3 position(vertex.pos[0],vertex.pos[1],vertex.pos[2]);
      if(!initialized) {
        minimum = position;
        maximum = position;
        initialized = true;
        continue;
        }
      minimum.x = std::min(minimum.x,position.x);
      minimum.y = std::min(minimum.y,position.y);
      minimum.z = std::min(minimum.z,position.z);
      maximum.x = std::max(maximum.x,position.x);
      maximum.y = std::max(maximum.y,position.y);
      maximum.z = std::max(maximum.z,position.z);
      }
    }

  if(!initialized)
    return false;
  out.assign(std::make_pair(minimum,maximum));
  return true;
  }

inline bool StaticMesh::computePackedSubMeshBounds(
    Bounds& out,
    const std::vector<Vertex>& vertices,
    const std::vector<uint32_t>& indices,
    const std::vector<uint8_t>& packedIndices,
    size_t iboOffset,
    size_t iboLength) noexcept {
  out = Bounds();
  constexpr size_t MaxIndices  = size_t(PackedMesh::MaxInd);
  constexpr size_t MaxPrimitives = size_t(PackedMesh::MaxPrim);
  constexpr size_t PackedStride = MaxPrimitives*4u;
  if(iboOffset%MaxIndices!=0 ||
     iboLength==0 || iboLength%MaxIndices!=0)
    return false;
  if(iboOffset>indices.size() || iboLength>indices.size()-iboOffset)
    return false;
  if(packedIndices.empty() || packedIndices.size()%PackedStride!=0)
    return false;

  const size_t packedMeshletCount = packedIndices.size()/PackedStride;
  bool initialized = false;
  const size_t meshletCount = iboLength/MaxIndices;
  for(size_t i=0; i<meshletCount; ++i) {
    const size_t firstIndex   = iboOffset+i*MaxIndices;
    const size_t meshletIndex = firstIndex/MaxIndices;
    if(meshletIndex>=packedMeshletCount)
      return false;

    const size_t metadata = meshletIndex*PackedStride+PackedStride-4u;
    size_t realIndexCount = MaxIndices;
    const uint8_t vertexCount = packedIndices[metadata+3u];
    if(vertexCount!=0u) {
      const uint8_t primitiveCount = packedIndices[metadata+2u];
      if(packedIndices[metadata+0u]!=packedIndices[metadata+1u] ||
         primitiveCount==0u ||
         size_t(primitiveCount)>=MaxPrimitives ||
         size_t(vertexCount)>size_t(PackedMesh::MaxVert))
        return false;
      realIndexCount = size_t(primitiveCount)*3u;
      }

    Bounds part;
    if(!computeSubMeshBounds(
        part,vertices,indices,firstIndex,realIndexCount))
      return false;
    if(!initialized) {
      out = part;
      initialized = true;
      }
    else {
      Bounds combined;
      combined.assign(out,part);
      out = combined;
      }
    }
  return initialized;
  }
