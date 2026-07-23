#include <metal_stdlib>

using namespace metal;

constant bool riosShadingPrototypeAlphaTest [[function_constant(0)]];

struct RendererIOSShadingPrototypeVertexIn {
  float3 position [[attribute(0)]];
  float4 color    [[attribute(1)]];
};

struct RendererIOSShadingPrototypeVertexOut {
  float4 position [[position]];
  half4  color    [[user(locn0)]];
};

struct RendererIOSShadingPrototypeMaterial {
  rgba8unorm<half4> compact [[raster_order_group(0)]];
};

struct RendererIOSShadingPrototypeMaterialStore {
  RendererIOSShadingPrototypeMaterial material [[imageblock_data]];
  half4 coverageColor [[color(0)]];
};

struct RendererIOSShadingPrototypeFinalColor {
  half4 finalColor [[color(0)]];
};

vertex RendererIOSShadingPrototypeVertexOut riosShadingPrototypeVertex(
    RendererIOSShadingPrototypeVertexIn in [[stage_in]]) {
  RendererIOSShadingPrototypeVertexOut out;
  out.position = float4(in.position,1.0f);
  out.color = half4(in.color);
  return out;
}

fragment RendererIOSShadingPrototypeMaterialStore
riosTileDeferredMaterialFragment(
    RendererIOSShadingPrototypeVertexOut in [[stage_in]]) {
  if(riosShadingPrototypeAlphaTest && in.color.a<half(0.5))
    discard_fragment();
  RendererIOSShadingPrototypeMaterialStore out;
  out.material.compact = in.color;
  out.coverageColor = half4(in.color.rgb,half(1.0));
  return out;
}

kernel void riosTileDeferredLighting(
    imageblock<RendererIOSShadingPrototypeMaterial,
               imageblock_layout_explicit> materialBlock,
    imageblock<RendererIOSShadingPrototypeFinalColor,
               imageblock_layout_implicit> finalColorBlock,
    ushort2 position [[thread_position_in_threadgroup]]) {
  threadgroup_imageblock RendererIOSShadingPrototypeMaterial* material =
      materialBlock.data(position);
  RendererIOSShadingPrototypeFinalColor output =
      finalColorBlock.read(position);
  if(output.finalColor.a>half(0.0)) {
    const half4 compact = material->compact;
    const half light = half(0.25)+compact.a*half(0.75);
    output.finalColor =
        half4(compact.rgb*light,half(1.0));
  } else {
    output.finalColor = half4(0.0h);
  }
  finalColorBlock.write(output,position);
}

kernel void riosForwardPlusBuildLightList(
    device uint* lightList [[buffer(0)]],
    uint position [[thread_position_in_grid]]) {
  if(position==0u)
    lightList[0] = 1u;
}

fragment float4 riosForwardPlusFragment(
    RendererIOSShadingPrototypeVertexOut in [[stage_in]],
    const device uint* lightList [[buffer(0)]]) {
  if(riosShadingPrototypeAlphaTest && in.color.a<half(0.5))
    discard_fragment();
  const float light = lightList[0]==1u ? 1.0f : 0.0f;
  return float4(float3(in.color.rgb)*light,1.0f);
}
