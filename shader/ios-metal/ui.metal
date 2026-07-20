#include <metal_stdlib>

using namespace metal;

struct RendererIOSUiVertexIn {
  float3 position [[attribute(0)]];
  float2 uv       [[attribute(1)]];
  float4 color    [[attribute(2)]];
};

struct RendererIOSUiColorVertexOut {
  float4 position [[position]];
  float4 color    [[user(locn0)]];
};

struct RendererIOSUiTextureVertexOut {
  float4 position [[position]];
  float4 color    [[user(locn0)]];
  float2 uv       [[user(locn1)]];
};

vertex RendererIOSUiColorVertexOut riosUiColorVertex(
    RendererIOSUiVertexIn in [[stage_in]]) {
  RendererIOSUiColorVertexOut out;
  out.position = float4(in.position,1.0f);
  out.position.y = -out.position.y;
  out.color = in.color;
  return out;
}

fragment float4 riosUiColorFragment(
    RendererIOSUiColorVertexOut in [[stage_in]]) {
  return in.color;
}

vertex RendererIOSUiTextureVertexOut riosUiTextureVertex(
    RendererIOSUiVertexIn in [[stage_in]]) {
  RendererIOSUiTextureVertexOut out;
  out.position = float4(in.position,1.0f);
  out.position.y = -out.position.y;
  out.color = in.color;
  out.uv = in.uv;
  return out;
}

fragment float4 riosUiTextureFragment(
    RendererIOSUiTextureVertexOut in [[stage_in]],
    texture2d<float,access::sample> texture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]) {
  return in.color*texture.sample(textureSampler,in.uv);
}
