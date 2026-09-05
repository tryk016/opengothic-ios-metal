#include <metal_stdlib>
using namespace metal;

struct IOSLandscapeDrawConstants {
  float4x4 viewProjection;
  float4x4 model;
  float4   baseColor;
  float2   uvOffset;
};

struct IOSDeformationConstants {
  uint boneOffset;
  uint morphOffset;
  uint morphCount;
  float fatness;
};

struct IOSLandscapeVertexIn {
  float3 position [[attribute(0)]];
  float3 normal   [[attribute(1)]];
  float2 uv       [[attribute(2)]];
  float4 color    [[attribute(3)]];
};

struct IOSLandscapeVertexOut {
  float4 position [[position]];
  float4 color;
  float2 uv;
};

struct alignas(16) IOSToneResolveConstants {
  float brightness;
  float contrast;
  float gamma;
  float exposure;
};

struct IOSToneResolveVertexOut {
  float4 position [[position]];
};

static_assert(sizeof(IOSToneResolveConstants)==16,
              "IOSToneResolveConstants size drifted");
static_assert(alignof(IOSToneResolveConstants)==16,
              "IOSToneResolveConstants alignment drifted");

static float3 riosInverseAcesToneMap(float3 color) {
  return (-0.59*color+0.03-
          sqrt(-1.0127*color*color+1.3702*color+0.0009))/
         (2.0*(2.43*color-2.51));
}

static float3 riosLiftLegacyLdrToScene(float3 color) {
  const float3 encoded = clamp(color,0.0,1.0);
  const float3 linear = pow(encoded,float3(2.2));
  return riosInverseAcesToneMap(linear);
}

static float3 riosAcesToneMap(float3 color) {
  return clamp(
      (color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),
      0.0,1.0);
}

static float riosInterleavedGradientNoise(float2 pixel) {
  return fract(52.9829189*fract(
      0.06711056*pixel.x+0.00583715*pixel.y));
}

vertex IOSLandscapeVertexOut riosLandscapeVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]]) {
  IOSLandscapeVertexOut out;
  const float4 world = draw.model*float4(in.position + in.normal*deformation.fatness,1.0);
  float4 clip = draw.viewProjection*world;
  clip.y = -clip.y;
  out.position = clip;
  out.color = in.color*draw.baseColor;
  out.uv = in.uv + draw.uvOffset;
  return out;
}

fragment float4 riosLandscapeFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  const float3 currentLdrRgb = texel.rgb*in.color.rgb;
  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);
}

fragment float4 riosLandscapeAlphaTestFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  if(texel.a<0.5)
    discard_fragment();
  const float3 currentLdrRgb = texel.rgb*in.color.rgb;
  return float4(riosLiftLegacyLdrToScene(currentLdrRgb),1.0);
}

fragment float4 riosLandscapeAdditiveFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  const float3 sceneRgb =
      riosLiftLegacyLdrToScene(texel.rgb*in.color.rgb)*3.0;
  return float4(sceneRgb,texel.a*in.color.a);
}

vertex IOSToneResolveVertexOut riosToneResolveVertex(
    uint vertexId [[vertex_id]]) {
  constexpr float2 positions[3] = {
    float2(-1.0,-1.0),
    float2( 3.0,-1.0),
    float2(-1.0, 3.0),
  };
  IOSToneResolveVertexOut out;
  out.position = float4(positions[vertexId],0.0,1.0);
  return out;
}

fragment float4 riosToneResolveFragment(
    IOSToneResolveVertexOut in [[stage_in]],
    texture2d<float, access::read> hdr [[texture(0)]],
    constant IOSToneResolveConstants& constants [[buffer(0)]]) {
  const uint2 pixel = uint2(in.position.xy);
  float3 color = hdr.read(pixel).rgb;
  color *= constants.exposure;
  color = max(float3(0.0),color+constants.brightness)*constants.contrast;
  color = riosAcesToneMap(color);
  color = pow(color,float3(constants.gamma));
  const float noise = riosInterleavedGradientNoise(in.position.xy);
  const float dither = ((noise*2.0)-1.0)/255.0;
  color += float3(dither);
  return float4(color,1.0);
}


struct IOSSkinnedVertex {
  packed_float3 normal;
  packed_float2 uv;
  uint color;
  packed_float3 position[4];
  uchar4 boneId;
  float weight[4];
};

struct IOSMorphLayer {
  uint indexOffset;
  uint sample0;
  uint sample1;
  float alpha;
  float intensity;
};



static_assert(sizeof(IOSSkinnedVertex)==92, "Resources::VertexA stride");
static_assert(__builtin_offsetof(IOSSkinnedVertex,uv)==12, "skinned UV offset");
static_assert(__builtin_offsetof(IOSSkinnedVertex,position)==24, "skinned positions offset");
static_assert(__builtin_offsetof(IOSSkinnedVertex,boneId)==72, "skinned IDs offset");
static_assert(__builtin_offsetof(IOSSkinnedVertex,weight)==76, "skinned weights offset");
static_assert(sizeof(IOSMorphLayer)==20, "morph layer stride");
static_assert(sizeof(IOSDeformationConstants)==16, "deformation constants size");

static IOSLandscapeVertexOut riosDeformedOutput(
    float3 world, float2 uv, float4 color,
    constant IOSLandscapeDrawConstants& draw) {
  IOSLandscapeVertexOut out;
  out.position = draw.viewProjection*float4(world,1.0);
  out.position.y = -out.position.y;
  out.color = color*draw.baseColor;
  out.uv = uv + draw.uvOffset;
  return out;
}

vertex IOSLandscapeVertexOut riosSkinnedVertex(
    uint vertexId [[vertex_id]],
    const device IOSSkinnedVertex* vertices [[buffer(0)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device float4x4* bones [[buffer(3)]]) {
  const IOSSkinnedVertex in = vertices[vertexId];
  float3 world = float3(0.0);
  for(uint i=0;i<4;++i)
    world += (bones[deformation.boneOffset+in.boneId[i]]*
              float4(float3(in.position[i]),1.0)).xyz*in.weight[i];
  const float3 normal = (draw.model*float4(float3(in.normal),0.0)).xyz;
  world += normal*deformation.fatness;
  const uint4 colorBits = uint4(in.color) >> uint4(0,8,16,24);
  const float4 color = float4(colorBits & 255u)/255.0;
  return riosDeformedOutput(world,float2(in.uv),color,draw);
}

vertex IOSLandscapeVertexOut riosMorphVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    uint vertexId [[vertex_id]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device IOSMorphLayer* layers [[buffer(3)]],
    const device int* indices [[buffer(4)]],
    const device float4* samples [[buffer(5)]]) {
  float3 local = in.position;
  for(uint i=0;i<deformation.morphCount;++i) {
    const IOSMorphLayer layer = layers[deformation.morphOffset+i];
    if(layer.intensity<=0.0)
      continue;
    const int index = indices[layer.indexOffset+vertexId];
    if(index<0)
      continue;
    local += mix(samples[layer.sample0+uint(index)].xyz,
                 samples[layer.sample1+uint(index)].xyz,layer.alpha)*layer.intensity;
  }
  const float3 normal = (draw.model*float4(in.normal,0.0)).xyz;
  const float3 world = (draw.model*float4(local,1.0)).xyz + normal*deformation.fatness;
  return riosDeformedOutput(world,in.uv,in.color,draw);
}

struct IOSGPUInstance {
  float4x4 model;
  float4 baseColor;
  float2 uvOffset;
  float fatness;
  uint padding;
};
static_assert(sizeof(IOSGPUInstance)==96, "native instance stride");

vertex IOSLandscapeVertexOut riosInstancedVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    uint instanceId [[instance_id]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    const device IOSGPUInstance* instances [[buffer(6)]]) {
  const IOSGPUInstance instance = instances[instanceId];
  IOSLandscapeVertexOut out;
  const float4 world = instance.model*float4(in.position+in.normal*instance.fatness,1.0);
  out.position = draw.viewProjection*world;
  out.position.y = -out.position.y;
  out.color = in.color*instance.baseColor;
  out.uv = in.uv+instance.uvOffset;
  return out;
}
