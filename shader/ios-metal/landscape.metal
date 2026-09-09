#include <metal_stdlib>
using namespace metal;

struct IOSLandscapeDrawConstants {
  float4x4 viewProjection;
  float4x4 model;
  float4   baseColor;
  float2   uvOffset;
  uint landscape;
  float waveMaxAmplitude;
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
  uint landscape [[flat]]; // Bits: terrain, water, particle.
  float3 world;
  float3 normal;
  float4 position [[position, invariant]];
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
  float2 uv;
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
  out.world = world.xyz;
  out.normal = (draw.model*float4(in.normal,0.0)).xyz;
  out.landscape = draw.landscape;
  out.color = in.color*draw.baseColor;
  out.uv = in.uv + draw.uvOffset;
  return out;
}

struct IOSSceneLightingConstants {
  float4x4 viewShadow[2];
  float4 sunDirection;
  float4 sunColor;
  float4 ambientColor;
  float4 cameraPosition;
  float4 shadowSlice;
  float4 skyParameters;
  float4 fogColor;
  float4 fogParameters;
  float4x4 inverseViewProjection;
  uint4 lightInfo;
};
struct IOSPointLightConstants {
  float4 positionRange;
  float4 color;
};
static_assert(sizeof(IOSSceneLightingConstants)==336, "scene lighting size");
static_assert(__builtin_offsetof(IOSSceneLightingConstants,inverseViewProjection)==256, "scene inverse VP offset");
static_assert(__builtin_offsetof(IOSSceneLightingConstants,lightInfo)==320, "scene light count offset");
static_assert(sizeof(IOSPointLightConstants)==32, "point light stride");

static float riosShadowPcf(depth2d<float> map, float3 position) {
  constexpr sampler shadowSampler(coord::normalized,address::clamp_to_edge,
                                  filter::linear,compare_func::greater_equal);
  const float2 uv = position.xy*0.5+0.5;
  const float texel = 1.0/float(map.get_width());
  const float z = max(0.0,position.z);
  float shadow = 0.0;
  shadow += map.sample_compare(shadowSampler,uv+texel*float2(-0.75, 0.25),z);
  shadow += map.sample_compare(shadowSampler,uv+texel*float2( 0.25, 0.25),z);
  shadow += map.sample_compare(shadowSampler,uv+texel*float2(-0.75,-0.75),z);
  shadow += map.sample_compare(shadowSampler,uv+texel*float2( 0.25,-0.75),z);
  return shadow*0.25;
}

static float riosSceneShadow(float3 world, float3 normal, bool transparent,
                            constant IOSSceneLightingConstants& scene,
                            depth2d<float> nearMap, depth2d<float> farMap) {
  if(scene.sunDirection.w==0.0)
    return 1.0;
  const float4 closeClip = scene.viewShadow[0]*float4(world+normal*(transparent ? 0.0 : 5.0),1.0);
  const float4 farClip = scene.viewShadow[1]*float4(world+normal*(transparent ? 0.0 : 25.0),1.0);
  if(abs(closeClip.w)<0.000001 || abs(farClip.w)<0.000001)
    return 1.0;
  const float3 close = closeClip.xyz/closeClip.w;
  const float3 far = farClip.xyz/farClip.w;
  constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
  const float4 depths = farMap.gather(nearest,far.xy*0.5+0.5);
  const float farDepth = max(max(depths.x,depths.y),max(depths.z,depths.w));
  if(all(abs(close.xy)<0.99) && farDepth<scene.shadowSlice.y)
    return riosShadowPcf(nearMap,close);
  return all(abs(far.xy)<1.0) ? riosShadowPcf(farMap,far) : 1.0;
}

static float3 riosTextureAlbedo(float3 color) {
  return riosInverseAcesToneMap(pow(clamp(color,0.0,1.0),float3(2.2))*0.78+0.001)*5.0;
}

static float3 riosSceneLighting(IOSLandscapeVertexOut in, bool transparent,
                               constant IOSSceneLightingConstants& scene,
                               const device IOSPointLightConstants* lights,
                               const device uint* lightGrid,
                               depth2d<float> nearMap, depth2d<float> farMap, float alpha = 1.0) {
  constexpr float invPi = 0.31830988618;
  const float3 normal = normalize(in.normal);
  const float shadow = riosSceneShadow(in.world,normal,transparent,scene,nearMap,farMap);
  float lambert = max(0.0,dot(normal,scene.sunDirection.xyz));
  if(transparent && (in.landscape&4u)!=0) {
    const float g = alpha*0.63;
    const float cosine = -dot(normalize(in.world-scene.cameraPosition.xyz),scene.sunDirection.xyz);
    const float denominator = 1.0+g*g-2.0*g*cosine;
    lambert = (1.0-g*g)*0.25*invPi/pow(denominator,1.5);
  }
  if((in.landscape&1u)!=0 && !transparent) {
    float3 flat = normalize(cross(dfdx(in.world),dfdy(in.world)));
    // Orient the derivative normal consistently across clip-Y conventions.
    flat *= dot(flat,normal)<0.0 ? -1.0 : 1.0;
    if(dot(flat,scene.sunDirection.xyz)<=0.01)
      lambert = 0.0;
  }
  const float3 night = float3(0.3,0.26,1.0)*0.36*invPi*scene.sunColor.w;
  const float3 ambient = scene.ambientColor.xyz+(normal.y*0.25+0.75)*night;
  float3 light = scene.sunColor.xyz*lambert*shadow*(transparent ? 1.0 : invPi);
  light += ambient*(transparent ? 2.0 : 1.0);
  if(!transparent && scene.lightInfo.x!=0u) {
    const uint2 tile = min(uint2(in.position.xy)/32u,uint2(lightGrid[0],lightGrid[1])-1u);
    const uint cell = 2u+2u*(tile.y*lightGrid[0]+tile.x);
    const uint offset = lightGrid[cell], count = lightGrid[cell+1u];
    for(uint i=0; i<count; ++i) {
      const IOSPointLightConstants point = lights[lightGrid[offset+i]];
      const float3 direction = point.positionRange.xyz-in.world;
      const float distanceSquared = dot(direction,direction);
      const float factor = distanceSquared/(point.positionRange.w*point.positionRange.w);
      if(factor>=1.0)
        continue;
      const float smoothFactor = max(1.0-factor*factor,0.0);
      const float cosine = max(0.0,dot(direction*rsqrt(max(distanceSquared,0.0001)),normal));
      light += point.color.rgb*(cosine/max(factor,0.005))*smoothFactor*smoothFactor*invPi*0.25;
    }
  }
  return light;
}

static float3 riosSceneFog(float3 color, float3 world,
                          constant IOSSceneLightingConstants& scene) {
  if(scene.fogParameters.y<=scene.fogParameters.x)
    return color;
  const float distance = length(world-scene.cameraPosition.xyz);
  const float density = smoothstep(scene.fogParameters.x,scene.fogParameters.y,distance);
  return mix(color,scene.fogColor.rgb,density);
}

fragment float4 riosLandscapeFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    const device IOSPointLightConstants* lights [[buffer(1)]],
    const device uint* lightGrid [[buffer(5)]],
    depth2d<float> shadowNear [[texture(1)]],
    depth2d<float> shadowFar [[texture(2)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  const float3 light = riosSceneLighting(in,false,scene,lights,lightGrid,shadowNear,shadowFar);
  const float3 color = riosSceneFog(riosTextureAlbedo(texel.rgb*in.color.rgb)*light,in.world,scene);
  return float4(color,1.0);
}

fragment float4 riosLandscapeAlphaTestFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    const device IOSPointLightConstants* lights [[buffer(1)]],
    const device uint* lightGrid [[buffer(5)]],
    depth2d<float> shadowNear [[texture(1)]],
    depth2d<float> shadowFar [[texture(2)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  if(texel.a*((in.landscape&4u)!=0 ? 1.0 : in.color.a)<0.5)
    discard_fragment();
  const float3 light = riosSceneLighting(in,false,scene,lights,lightGrid,shadowNear,shadowFar);
  const float3 color = riosSceneFog(riosTextureAlbedo(texel.rgb*in.color.rgb)*light,in.world,scene);
  return float4(color,1.0);
}

fragment float4 riosLandscapeTransparentFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    const device IOSPointLightConstants* lights [[buffer(1)]],
    const device uint* lightGrid [[buffer(5)]],
    depth2d<float> shadowNear [[texture(1)]],
    depth2d<float> shadowFar [[texture(2)]]) {
  const float4 texel = baseColorTexture.sample(baseColorSampler,in.uv);
  const float3 light = riosSceneLighting(in,true,scene,lights,lightGrid,shadowNear,shadowFar,texel.a*in.color.a);
  const float3 color = riosSceneFog(riosTextureAlbedo(texel.rgb*in.color.rgb)*light,in.world,scene);
  return float4(color,texel.a*in.color.a);
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
  out.uv = positions[vertexId]*float2(0.5,-0.5)+0.5;
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

fragment float4 riosSavePreviewFragment(
    IOSToneResolveVertexOut in [[stage_in]],
    texture2d<float> hdr [[texture(0)]],
    constant IOSToneResolveConstants& constants [[buffer(0)]]) {
  constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
  float3 color = hdr.sample(linear,in.uv).rgb*constants.exposure;
  color = max(float3(0.0),color+constants.brightness)*constants.contrast;
  return float4(pow(riosAcesToneMap(color),float3(constants.gamma)),1.0);
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
    float3 world, float3 normal, float2 uv, float4 color,
    constant IOSLandscapeDrawConstants& draw) {
  IOSLandscapeVertexOut out;
  out.position = draw.viewProjection*float4(world,1.0);
  out.position.y = -out.position.y;
  out.world = world;
  out.normal = normal;
  out.landscape = draw.landscape;
  out.color = color*draw.baseColor;
  out.uv = uv + draw.uvOffset;
  return out;
}

static float3 riosSkinPosition(const IOSSkinnedVertex in,
    const device float4x4* bones, uint offset) {
  float3 world = float3(0.0);
  for(uint i=0;i<4;++i)
    world += (bones[offset+in.boneId[i]]*float4(float3(in.position[i]),1.0)).xyz*in.weight[i];
  return world;
}

static float3 riosMorphPosition(float3 local, uint vertexId,
    constant IOSDeformationConstants& deformation,
    const device IOSMorphLayer* layers, const device int* indices,
    const device float4* samples) {
  for(uint i=0;i<deformation.morphCount;++i) {
    const IOSMorphLayer layer = layers[deformation.morphOffset+i];
    if(layer.intensity<=0.0)
      continue;
    const int index = indices[layer.indexOffset+vertexId];
    if(index>=0)
      local += mix(samples[layer.sample0+uint(index)].xyz,
                   samples[layer.sample1+uint(index)].xyz,layer.alpha)*layer.intensity;
  }
  return local;
}

vertex IOSLandscapeVertexOut riosSkinnedVertex(
    uint vertexId [[vertex_id]],
    const device IOSSkinnedVertex* vertices [[buffer(0)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device float4x4* bones [[buffer(3)]]) {
  const IOSSkinnedVertex in = vertices[vertexId];
  const float3 normal = (draw.model*float4(float3(in.normal),0.0)).xyz;
  const float3 world = riosSkinPosition(in,bones,deformation.boneOffset)+normal*deformation.fatness;
  const float4 color = float4((uint4(in.color)>>uint4(0,8,16,24))&255u)/255.0;
  return riosDeformedOutput(world,normal,float2(in.uv),color,draw);
}

vertex IOSLandscapeVertexOut riosMorphVertex(
    IOSLandscapeVertexIn in [[stage_in]],
    uint vertexId [[vertex_id]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device IOSMorphLayer* layers [[buffer(3)]],
    const device int* indices [[buffer(4)]],
    const device float4* samples [[buffer(5)]]) {
  const float3 local = riosMorphPosition(in.position,vertexId,deformation,layers,indices,samples);
  const float3 normal = (draw.model*float4(in.normal,0.0)).xyz;
  const float3 world = (draw.model*float4(local,1.0)).xyz+normal*deformation.fatness;
  return riosDeformedOutput(world,normal,in.uv,in.color,draw);
}

struct IOSGPUInstance {
  float4x4 model;
  float4 baseColor;
  float2 uvOffset;
  float fatness;
  uint landscape;
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
  out.world = world.xyz;
  out.normal = (instance.model*float4(in.normal,0.0)).xyz;
  out.landscape = instance.landscape;
  out.color = in.color*instance.baseColor;
  out.uv = in.uv+instance.uvOffset;
  return out;
}

fragment void riosShadowAlphaTestFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]]) {
  if(baseColorTexture.sample(baseColorSampler,in.uv).a*((in.landscape&4u)!=0 ? 1.0 : in.color.a)<0.5)
    discard_fragment();
}

static float riosAtmosphereDistance(float3 position, float3 direction, float radius) {
  const float b = dot(position,direction);
  const float d = b*b-dot(position,position)+radius*radius;
  if(d<0.0)
    return -1.0;
  const float near = -b-sqrt(d), far = -b+sqrt(d);
  return near>0.0 ? near : far;
}

static float3 riosAtmosphereExtinction(float altitude) {
  const float ray = exp(-altitude/8.0), mie = exp(-altitude/1.2);
  const float ozone = max(0.0,1.0-abs(altitude-25.0)/15.0);
  return (float3(0.175,0.409,1.0)*33.1*ray+8.396*mie+float3(0.650,1.881,0.085)*ozone)*0.001;
}

static float3 riosAtmosphereSun(float3 position, float3 sun) {
  if(riosAtmosphereDistance(position,sun,6360.0)>0.0)
    return float3(0.0);
  const float distance = riosAtmosphereDistance(position,sun,6460.0);
  float3 opticalDepth = 0.0;
  for(uint i=0;i<8;++i) {
    const float a = float(i)/8.0, b = float(i+1)/8.0;
    const float start = a*a*distance, end = b*b*distance;
    const float altitude = max(0.0,length(position+sun*((start+end)*0.5))-6360.0);
    opticalDepth += riosAtmosphereExtinction(altitude)*(end-start);
  }
  return exp(-opticalDepth);
}

kernel void riosSkyLut(
    texture2d<float,access::write> output [[texture(0)]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    uint2 pixel [[thread_position_in_grid]]) {
  constexpr float pi = 3.14159265359;
  const float2 uv = (float2(pixel)+0.5)/float2(output.get_width(),output.get_height());
  const float v = uv.y*2.0-1.0;
  const float altitude = copysign(v*v,v)*pi*0.5;
  const float azimuth = (uv.x-0.5)*2.0*pi;
  const float3 ray = float3(cos(altitude)*sin(azimuth),sin(altitude),-cos(altitude)*cos(azimuth));
  const float3 origin = float3(0,6360.0+max(0.001,scene.cameraPosition.w*0.001),0);
  float distance = riosAtmosphereDistance(origin,ray,6460.0);
  const float ground = riosAtmosphereDistance(origin,ray,6360.0);
  if(ground>0.0)
    distance = min(distance,ground);
  const float cosine = dot(ray,scene.sunDirection.xyz);
  const float rayPhase = 3.0/(16.0*pi)*(1.0+cosine*cosine);
  const float miePhase = 3.0/(8.0*pi)*0.36*(1.0+cosine*cosine)/
                         (2.64*pow(1.64-1.6*cosine,1.5));
  float3 radiance = 0.0, transmittance = 1.0;
  for(uint i=0;i<24;++i) {
    const float a = float(i)/24.0, b = float(i+1)/24.0;
    const float start = a*a*distance, end = b*b*distance;
    const float3 position = origin+ray*((start+end)*0.5);
    const float height = max(0.0,length(position)-6360.0);
    const float3 extinction = riosAtmosphereExtinction(height);
    const float3 segment = exp(-extinction*(end-start));
    const float3 scattering = (float3(0.175,0.409,1.0)*33.1*exp(-height/8.0)*rayPhase+
                               3.996*exp(-height/1.2)*miePhase)*0.001;
    radiance += transmittance*scattering*riosAtmosphereSun(position,scene.sunDirection.xyz)*
                (1.0-segment)/max(extinction,float3(0.000001));
    transmittance *= segment;
  }
  radiance *= scene.skyParameters.w;
  radiance += float3(0.3,0.26,1.0)*0.012*scene.skyParameters.z*scene.sunColor.w;
  const float clouds = scene.skyParameters.x;
  radiance = mix(radiance,float3(dot(radiance,float3(0.2125,0.7154,0.0721)))*0.7,clouds);
  output.write(float4(radiance,1.0),pixel);
}

struct IOSSkyVertexOut {
  float4 position [[position]];
  float2 clip;
};

vertex IOSSkyVertexOut riosSkyVertex(uint index [[vertex_id]]) {
  const float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
  IOSSkyVertexOut out;
  out.clip = positions[index];
  out.position = float4(out.clip.x,-out.clip.y,1,1);
  return out;
}

static float4 riosSkySprite(float3 ray, float3 direction, float size,
                           texture2d<float> texture, sampler smp) {
  const float3 right = normalize(cross(direction,abs(direction.y)>0.99 ? float3(0,0,1) : float3(0,1,0)));
  const float3 up = cross(right,direction);
  const float2 uv = float2(dot(ray,right),-dot(ray,up))/size*0.5+0.5;
  if(dot(ray,direction)<=0.0 || any(uv<0.0) || any(uv>1.0))
    return 0.0;
  return texture.sample(smp,uv);
}

static float3 riosSkyColor(float3 ray,
    constant IOSSceneLightingConstants& scene, constant float4& cloudOffsets,
    texture2d<float> sky, array<texture2d<float>,6> images) {
  constexpr float pi = 3.14159265359;
  constexpr sampler skySampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
  constexpr sampler imageSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
  const float altitude = asin(clamp(ray.y,-1.0,1.0))/(pi*0.5);
  const float2 uv = float2(atan2(ray.x,-ray.z)/(2.0*pi)+0.5,
                          copysign(sqrt(abs(altitude)),altitude)*0.5+0.5);
  float3 color = sky.sample(skySampler,uv).rgb;
  const float night = scene.skyParameters.z;
  if(ray.y>0.0) {
    const float3 origin = float3(0,6360.0+scene.cameraPosition.w*0.001,0);
    const float distance = riosAtmosphereDistance(origin,ray,6366.0);
    const float3 cloudAt = origin+ray*distance;
    const float2 cloudUv = 2000.0*float2(atan2(cloudAt.z,cloudAt.y),atan2(cloudAt.x,cloudAt.y));
    const float4 day0 = images[0].sample(imageSampler,cloudUv*0.3+cloudOffsets.xy);
    const float4 day1 = images[1].sample(imageSampler,cloudUv*0.3+cloudOffsets.zw);
    const float4 stars = images[2].sample(imageSampler,cloudUv*0.6+0.5);
    const float4 night1 = images[3].sample(imageSampler,cloudUv*0.3+cloudOffsets.zw);
    const float4 day = (day0+day1)*0.5;
    const float3 highlight = max(color,scene.ambientColor.rgb);
    color += pow(day.rgb,float3(2.2))*highlight*day.a*(1.0-night);
    color += (pow(stars.rgb,float3(2.2))*stars.a+pow(night1.rgb,float3(2.2))*night1.a*0.1)*
             night*scene.sunColor.w*0.896;
    const float4 sun = riosSkySprite(ray,scene.sunDirection.xyz,0.025,images[4],imageSampler);
    color += sun.rgb*sun.a*scene.sunColor.rgb;
    const float4 moon = riosSkySprite(ray,normalize(float3(-1,1,0)),0.05,images[5],imageSampler);
    color += riosLiftLegacyLdrToScene(moon.rgb)*moon.a*night*scene.sunColor.w*0.32;
  }
  return color;
}

fragment float4 riosSkyFragment(
    IOSSkyVertexOut in [[stage_in]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    constant float4& cloudOffsets [[buffer(2)]],
    texture2d<float> sky [[texture(0)]],
    array<texture2d<float>,6> images [[texture(3)]]) {
  const float4 far = scene.inverseViewProjection*float4(in.clip,1,1);
  const float4 near = scene.inverseViewProjection*float4(in.clip,0,1);
  return float4(riosSkyColor(normalize(far.xyz/far.w-near.xyz/near.w),
                            scene,cloudOffsets,sky,images),1.0);
}

struct IOSRainVertexOut {
  float4 position [[position]];
  float2 uv;
};

static float riosRainHash(uint value) {
  value = (value^(value>>16))*2246822519u;
  value = (value^(value>>13))*3266489917u;
  return float(value&0xffffu)/65535.0;
}

vertex IOSRainVertexOut riosRainVertex(
    uint vertexId [[vertex_id]], uint instance [[instance_id]],
    constant float4x4& viewProjection [[buffer(0)]],
    constant IOSSceneLightingConstants& scene [[buffer(1)]]) {
  const float2 corners[6] = {float2(-1,-1),float2(1,1),float2(1,-1),
                             float2(-1,-1),float2(-1,1),float2(1,1)};
  const int2 cell = int2(floor(scene.cameraPosition.xz/100.0))+int2(instance%16,instance/16)-8;
  const uint seed = uint(cell.x)*73856093u ^ uint(cell.y)*19349663u;
  const float phase = fract(riosRainHash(seed)+scene.fogParameters.z*0.85);
  float3 center = float3((float(cell.x)+riosRainHash(seed+1))*100.0,
                         scene.cameraPosition.y+600.0-phase*1200.0,
                         (float(cell.y)+riosRainHash(seed+2))*100.0);
  const float3 right = normalize(float3(viewProjection[0][0],0,viewProjection[2][0]));
  const float2 corner = corners[vertexId];
  center += right*corner.x*0.65+float3(-2.0,18.0,0)*corner.y;
  IOSRainVertexOut out;
  out.position = viewProjection*float4(center,1);
  out.position.y = -out.position.y;
  out.uv = corner;
  return out;
}

fragment float4 riosRainFragment(IOSRainVertexOut in [[stage_in]],
                                 constant IOSSceneLightingConstants& scene [[buffer(0)]]) {
  const float alpha = (1.0-abs(in.uv.x))*(1.0-abs(in.uv.y))*scene.skyParameters.y*0.35;
  const float3 color = float3(0.55,0.65,0.8)*(scene.ambientColor.rgb+scene.sunColor.rgb*0.1+0.025);
  return float4(color,alpha);
}


struct IOSWaterWave {
  float3 offset;
  float3 normal;
};

static IOSWaterWave riosWaterWave(float3 pos, float footprint, uint iterations,
                                  float amplitude, uint tick) {
  float3 offset = 0.0;
  float3 tangent = float3(1,0,0), binormal = float3(0,0,1);
  const float weightSum = (1.0-pow(0.8,float(iterations)))/0.2;
  float frequency = 0.003, speed = 2.0, angle = 0.0, weight = 1.0;
  for(uint i=0;i<iterations;++i) {
    if(frequency*footprint>2.0)
      break;
    const float2 dir = float2(cos(angle),sin(angle));
    const float phase = dot(dir,pos.xz)*frequency+float(tick)*0.001*speed;
    const float a = weight*max(10.0,amplitude*0.5)/weightSum;
    const float sn = a*sin(phase), cs = a*cos(phase);
    binormal += float3(-dir.x*dir.y*sn,dir.y*cs,-dir.y*dir.y*sn)*frequency;
    tangent += float3(-dir.x*dir.x*sn,dir.x*cs,-dir.x*dir.y*sn)*frequency;
    offset += float3(dir.x*cs,sn,dir.y*cs);
    pos.xz += cs*weight*dir*0.48;
    angle += 12.0;
    weight *= 0.8;
    frequency *= 1.18;
    speed *= 1.07;
  }
  return {offset,normalize(cross(binormal,tangent))};
}

struct IOSWaterControlVertex {
  packed_float3 position;
  packed_float3 normal;
  packed_float2 uv;
  uint color;
};
static_assert(sizeof(IOSWaterControlVertex)==36, "water control vertex stride");

kernel void riosWaterFactors(
    uint patch [[thread_position_in_grid]],
    const device IOSWaterControlVertex* vertices [[buffer(0)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    const device uint* indices [[buffer(2)]],
    device half4* factors [[buffer(3)]],
    constant uint& patchCount [[buffer(4)]]) {
  if(patch>=patchCount)
    return;
  float4 clip[3];
  for(uint i=0;i<3;++i)
    clip[i] = draw.viewProjection*draw.model*float4(float3(vertices[indices[patch*3+i]].position),1.0);
  // Each shared edge depends only on its own endpoints, including near-plane crossings.
  float3 edges;
  for(uint i=0;i<3;++i) {
    const float4 a = clip[(i+1)%3], b = clip[(i+2)%3];
    edges[i] = a.w<=0.0 || b.w<=0.0 ? 16.0 : min((length(a.xyz/a.w-b.xyz/b.w)+0.5)*16.0+1.0,16.0);
  }
  float inside = 16.0;
  if(clip[0].w>0.0 && clip[1].w>0.0 && clip[2].w>0.0) {
    const float2 a = clip[0].xy/clip[0].w-clip[2].xy/clip[2].w;
    const float2 b = clip[1].xy/clip[1].w-clip[2].xy/clip[2].w;
    inside = min((abs(a.x*b.y-b.x*a.y)+0.5)*16.0,16.0);
  }
  factors[patch] = half4(float4(edges,inside));
}

[[patch(triangle,3)]]
vertex IOSLandscapeVertexOut riosWaterPatchVertex(
    uint patch [[patch_id]], float3 barycentric [[position_in_patch]],
    const device IOSWaterControlVertex* vertices [[buffer(0)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    const device uint* indices [[buffer(7)]],
    constant IOSSceneLightingConstants& scene [[buffer(8)]]) {
  float3 position = 0.0, normal = 0.0;
  float2 uv = 0.0;
  float4 color = 0.0;
  for(uint i=0;i<3;++i) {
    const IOSWaterControlVertex v = vertices[indices[patch*3+i]];
    position += float3(v.position)*barycentric[i];
    normal += float3(v.normal)*barycentric[i];
    uv += float2(v.uv)*barycentric[i];
    color += float4((uint4(v.color)>>uint4(0,8,16,24))&255u)/255.0*barycentric[i];
  }
  float3 world = (draw.model*float4(position,1.0)).xyz;
  normal = normalize((draw.model*float4(normal,0.0)).xyz);
  if(draw.waveMaxAmplitude>0.0) {
    const IOSWaterWave wave = riosWaterWave(world,0.0,10,draw.waveMaxAmplitude,scene.lightInfo.y);
    world += wave.offset;
    normal = wave.normal;
  }
  return riosDeformedOutput(world,normal,uv,color,draw);
}

static float riosWaterFresnel(float3 incident, float3 normal, float ior) {
  float cosine = clamp(dot(incident,normal),-1.0,1.0);
  const float etaIn = cosine>0.0 ? ior : 1.0;
  const float etaOut = cosine>0.0 ? 1.0 : ior;
  const float sine = etaIn/etaOut*sqrt(max(0.0,1.0-cosine*cosine));
  if(sine>=1.0)
    return 1.0;
  const float transmitted = sqrt(max(0.0,1.0-sine*sine));
  cosine = abs(cosine);
  const float rs = (etaOut*cosine-etaIn*transmitted)/(etaOut*cosine+etaIn*transmitted);
  const float rp = (etaIn*cosine-etaOut*transmitted)/(etaIn*cosine+etaOut*transmitted);
  return (rs*rs+rp*rp)*0.5;
}

static float3 riosScenePosition(float2 uv, float depth,
                                constant IOSSceneLightingConstants& scene) {
  const float4 position = scene.inverseViewProjection*float4(uv*2.0-1.0,depth,1.0);
  return position.xyz/position.w;
}

fragment float4 riosWaterFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    constant float4& cloudOffsets [[buffer(2)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(3)]],
    array<texture2d<float>,6> images [[texture(3)]],
    texture2d<float> sceneColor [[texture(9)]],
    depth2d<float> sceneDepth [[texture(10)]],
    texture2d<float> sky [[texture(11)]]) {
  constexpr sampler linearClamp(coord::normalized,address::clamp_to_edge,filter::linear);
  constexpr sampler nearestClamp(coord::normalized,address::clamp_to_edge,filter::nearest);
  const float2 uv = in.position.xy/float2(sceneColor.get_width(),sceneColor.get_height());
  const float3 view = normalize(in.world-scene.cameraPosition.xyz);
  const float footprint = max(length(dfdx(in.world)),length(dfdy(in.world)));
  float3 normal = riosWaterWave(in.world,footprint,32,draw.waveMaxAmplitude,scene.lightInfo.y).normal;
  if(dot(normal,view)>0.0)
    normal = -normal;
  const bool underwater = scene.lightInfo.z!=0;
  float3 reflection = reflect(view,normal);
  const float fresnel = riosWaterFresnel(reflection,normal,underwater ? 1.52 : 1.0/1.52);
  float3 back = sceneColor.sample(linearClamp,uv).rgb;
  if(underwater)
    return float4(back*(1.0-fresnel),1.0);
  float depth = sceneDepth.sample(nearestClamp,uv);
  const float3 ground = riosScenePosition(uv,depth,scene);
  const float thickness = max(0.0,(draw.viewProjection*float4(ground-in.world,0.0)).w);
  const float2 refractedUv = uv+normal.xz*min(thickness*0.01,1.0)*0.1;
  const float refractedDepth = sceneDepth.sample(nearestClamp,refractedUv);
  if(refractedDepth>in.position.z) {
    back = sceneColor.sample(linearClamp,refractedUv).rgb;
    depth = refractedDepth;
  }
  const float distance = length(riosScenePosition(uv,depth,scene)-in.world);
  const float3 transmittance = exp(-distance/5000.0*float3(4,2,1)*2.5);
  const float solarFresnel = riosWaterFresnel(scene.sunDirection.xyz,normal,1.0/1.52);
  const float3 scatter = solarFresnel*scene.sunColor.rgb*(1.0-exp(-distance/20000.0))*max(scene.sunDirection.y,0.0);
  reflection = normalize(float3(reflection.x,max(0.0,reflection.y),reflection.z));
  const float3 reflected = scene.lightInfo.w!=0
      ? riosSkyColor(reflection,scene,cloudOffsets,sky,images) : float3(0.0);
  return float4((back+scatter)*transmittance*(1.0-fresnel)+reflected*float3(0.8,0.9,1.0)*fresnel,1.0);
}

fragment float4 riosGhostFragment(
    IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> baseColorTexture [[texture(0)]],
    sampler baseColorSampler [[sampler(0)]],
    texture2d<float> sceneColor [[texture(9)]],
    constant float4x4& viewProjection [[buffer(4)]]) {
  constexpr sampler linearClamp(coord::normalized,address::clamp_to_edge,filter::linear);
  const float3 projectedNormal = (viewProjection*float4(normalize(in.normal),0.0)).xyz;
  const float2 uv = in.position.xy/float2(sceneColor.get_width(),sceneColor.get_height())+projectedNormal.xy*0.005;
  const float3 back = sceneColor.sample(linearClamp,uv).rgb;
  const float3 tint = riosTextureAlbedo(baseColorTexture.sample(baseColorSampler,in.uv).rgb*in.color.rgb)*5.0;
  return float4(mix(back*tint,back,0.6),1.0);
}

fragment float4 riosUnderwaterFragment(
    IOSSkyVertexOut in [[stage_in]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    texture2d<float> sceneColor [[texture(9)]],
    depth2d<float> sceneDepth [[texture(10)]]) {
  const uint2 pixel = uint2(in.position.xy);
  const float2 uv = in.position.xy/float2(sceneColor.get_width(),sceneColor.get_height());
  const float distance = length(riosScenePosition(uv,sceneDepth.read(pixel),scene)-scene.cameraPosition.xyz);
  const float3 transmittance = exp(-distance/5000.0*float3(4,2,1)*1.25);
  const float fresnel = riosWaterFresnel(scene.sunDirection.xyz,float3(0,1,0),1.0/1.52);
  const float3 scatter = fresnel*scene.sunColor.rgb*(1.0-exp(-distance/20000.0));
  return float4((sceneColor.read(pixel).rgb+scatter)*transmittance,1.0);
}

struct IOSParticleVertex {
  packed_float3 position;
  uint color;
  packed_float3 size;
  uint bits;
  packed_float3 direction;
  uint colorB;
};
static_assert(sizeof(IOSParticleVertex)==48, "particle storage stride");

struct IOSParticleCameraConstants {
  float4x4 viewProjection;
  float4x4 view;
  float4 left, top, depth;
};
static_assert(sizeof(IOSParticleCameraConstants)==176, "particle camera ABI");

vertex IOSLandscapeVertexOut riosParticleVertex(
    uint vertexId [[vertex_id]], uint instanceId [[instance_id]],
    const device IOSParticleVertex* particles [[buffer(0)]],
    constant IOSParticleCameraConstants& camera [[buffer(1)]]) {
  const IOSParticleVertex particle = particles[instanceId];
  const float U[6] = {0,1,0,0,1,1};
  const float V[6] = {1,0,0,1,1,0};
  const float dxQ[6] = {-0.5,0.5,-0.5,-0.5,0.5,0.5};
  const float dyQ[6] = {0.5,-0.5,-0.5,0.5,0.5,-0.5};
  const float dxT[6] = {-0.3333,1.5,-0.3333,0,0,0};
  const float dyT[6] = {1.5,-0.3333,-0.3333,0,0,0};
  float3 position = float3(particle.position), size = float3(particle.size);
  float3 direction = float3(particle.direction);
  float3 left = camera.left.xyz, top = camera.top.xyz, depth = camera.depth.xyz;
  float3 normal = -depth;
  float2 uv = float2(U[vertexId],V[vertexId]);
  uint packedColor = particle.color;
  const bool trail = (particle.bits&8u)!=0;
  const uint orientation = (particle.bits>>4u)&3u;
  if((particle.bits&4u)!=0) {
    left.y = 0.0;
    top = float3(0,-1,0);
  }
  if(trail) {
    normal = float3(0,1,0);
    if(dyQ[vertexId]>0.0)
      packedColor = particle.colorB;
    float3 side = cross(depth,direction);
    const float sideLength = length(side);
    side = sideLength>0.0 ? side*(size.x/sideLength) : float3(0.0);
    position += dxQ[vertexId]*side + (dyQ[vertexId]+0.5)*direction;
    uv = float2(dxQ[vertexId]+0.5,1.0-mix(size.y,size.z,dyQ[vertexId]+0.5));
  } else if(orientation==2u) {
    const float directionLength = length(direction);
    if(directionLength>0.0)
      direction /= directionLength;
    top = -direction;
    left = -cross(top,depth);
  } else if(orientation==1u) {
    float3 dir = (camera.view*float4(direction,0.0)).xyz;
    const float directionLength = length(dir);
    dir = directionLength>0.0 ? dir/directionLength : float3(0.0);
    const float scale = 1.5*(1.0-abs(dir.z));
    const float angle = (dir.x==0.0 && dir.y==0.0 ? 0.0 : atan2(dir.y,-dir.x)) + M_PI_F*0.5;
    const float3 rotatedLeft = left*cos(angle)-top*sin(angle);
    top = (left*sin(angle)+top*cos(angle))*scale;
    left = rotatedLeft*scale;
  }
  if((particle.bits&2u)!=0)
    position += left*dxQ[vertexId]*size.x + top*dyQ[vertexId]*size.y;
  else if(!trail)
    position += left*dxT[vertexId]*size.x + top*dyT[vertexId]*size.y;
  if((particle.bits&1u)!=0)
    position -= size.z*depth;
  IOSLandscapeVertexOut out;
  out.position = camera.viewProjection*float4(position,1.0);
  out.position.y = -out.position.y;
  out.world = position;
  out.normal = normal;
  out.landscape = 4u; // Particle forward lighting uses a phase function.
  out.uv = uv;
  out.color = float4((uint4(packedColor)>>uint4(0,8,16,24))&255u)/255.0;
  return out;
}

#include "fsr1.metal"

#include "motion.metal"
