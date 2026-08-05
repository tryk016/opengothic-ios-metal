#include <metal_stdlib>
using namespace metal;

struct IOSLandscapeDrawConstants {
  float4x4 viewProjection;
  float4x4 model;
  float4   baseColor;
  float2   uvOffset;
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
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]]) {
  IOSLandscapeVertexOut out;
  const float4 world = draw.model*float4(in.position,1.0);
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
