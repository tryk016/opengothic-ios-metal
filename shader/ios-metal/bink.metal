#include <metal_stdlib>

using namespace metal;

struct RendererIOSBinkVertexOutput {
  float4 position [[position]];
  };

struct RendererIOSBinkConstants {
  uint strideY;
  uint strideU;
  uint strideV;
  uint reserved;
  };

vertex RendererIOSBinkVertexOutput riosBinkVertex(
    uint vertexId [[vertex_id]]) {
  RendererIOSBinkVertexOutput out;
  const float2 uv = float2(float((vertexId << 1u) & 2u),
                           float(vertexId & 2u));
  out.position = float4(uv*2.0f-1.0f,1.0f,1.0f);
  return out;
  }

uint rendererIOSBinkByte(const device uint* plane, uint index) {
  const uint packed = plane[index/4u];
  return (packed >> ((index%4u)*8u)) & 0xFFu;
  }

fragment float4 riosBinkFragment(
    float4 position [[position]],
    const device uint* planeY [[buffer(0)]],
    const device uint* planeU [[buffer(1)]],
    const device uint* planeV [[buffer(2)]],
    constant RendererIOSBinkConstants& constants [[buffer(3)]]) {
  const uint2 at = uint2(position.xy);
  const uint yIndex = at.x + at.y*constants.strideY;
  const uint uIndex = at.x/2u + (at.y/2u)*constants.strideU;
  const uint vIndex = at.x/2u + (at.y/2u)*constants.strideV;

  const float y = float(rendererIOSBinkByte(planeY,yIndex));
  const float u = float(rendererIOSBinkByte(planeU,uIndex));
  const float v = float(rendererIOSBinkByte(planeV,vIndex));

  const float r = 1.164f*(y-16.0f) + 1.596f*(v-128.0f);
  const float g = 1.164f*(y-16.0f) - 0.813f*(v-128.0f)
                - 0.391f*(u-128.0f);
  const float b = 1.164f*(y-16.0f) + 2.018f*(u-128.0f);
  return float4(clamp(float3(r,g,b),0.0f,255.0f)/255.0f,1.0f);
  }
