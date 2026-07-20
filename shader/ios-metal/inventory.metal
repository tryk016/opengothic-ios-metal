#include <metal_stdlib>

using namespace metal;

struct RendererIOSInventoryVertexIn {
  float3 position [[attribute(0)]];
  float3 normal   [[attribute(1)]];
  float2 uv       [[attribute(2)]];
  uint   color    [[attribute(3)]];
};

struct RendererIOSInventoryVertexOut {
  float4 position [[position]];
  float2 uv       [[user(locn0)]];
};

vertex RendererIOSInventoryVertexOut riosInventoryVertex(
    RendererIOSInventoryVertexIn in [[stage_in]],
    constant float4x4& viewProject [[buffer(0)]]) {
  RendererIOSInventoryVertexOut out;
  out.uv = in.uv;
  out.position = viewProject*float4(in.position,1.0f);
  out.position.y = -out.position.y;
  return out;
}

fragment float4 riosInventoryFragment(
    RendererIOSInventoryVertexOut in [[stage_in]],
    texture2d<float,access::sample> texture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]) {
  const float4 texel = texture.sample(textureSampler,in.uv);
  if(texel.a<0.5f)
    discard_fragment();
  return texel;
}
