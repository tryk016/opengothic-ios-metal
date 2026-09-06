struct IOSMotionConstants {
  float4x4 previousModel, previousViewProjection;
  float4 jitter; // Current and previous input-pixel offsets.
  float4 extent; // Current and previous input dimensions.
};
static_assert(sizeof(IOSMotionConstants)==160, "motion constants ABI");

struct IOSMotionVertexOut {
  float4 position [[position, invariant]];
  float4 previousClip;
  float2 uv;
  float alpha;
};
struct IOSMotionOutput {
  float2 motion [[color(0)]];
  float reactive [[color(1)]];
};

static IOSMotionVertexOut riosMotionOutput(float3 world, float3 previousWorld,
    float2 uv, float alpha, constant IOSLandscapeDrawConstants& draw,
    constant IOSMotionConstants& motion) {
  IOSMotionVertexOut out;
  out.position=draw.viewProjection*float4(world,1.0);
  out.position.y=-out.position.y;
  out.previousClip=motion.previousViewProjection*float4(previousWorld,1.0);
  out.uv=uv;
  out.alpha=alpha;
  return out;
}

vertex IOSMotionVertexOut riosMotionVertex(IOSLandscapeVertexIn in [[stage_in]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    constant IOSMotionConstants& motion [[buffer(9)]]) {
  const float4 local=float4(in.position+in.normal*deformation.fatness,1.0);
  return riosMotionOutput((draw.model*local).xyz,(motion.previousModel*local).xyz,
      in.uv+draw.uvOffset,in.color.a*draw.baseColor.a,draw,motion);
}

vertex IOSMotionVertexOut riosMotionSkinnedVertex(uint vertexId [[vertex_id]],
    const device IOSSkinnedVertex* vertices [[buffer(0)]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device float4x4* bones [[buffer(3)]],
    constant IOSMotionConstants& motion [[buffer(9)]],
    const device float4x4* previousBones [[buffer(10)]]) {
  const IOSSkinnedVertex in=vertices[vertexId];
  const float4 normal=float4(float3(in.normal),0.0);
  const float3 world=riosSkinPosition(in,bones,deformation.boneOffset)+
      (draw.model*normal).xyz*deformation.fatness;
  const float3 previous=riosSkinPosition(in,previousBones,deformation.boneOffset)+
      (motion.previousModel*normal).xyz*deformation.fatness;
  return riosMotionOutput(world,previous,float2(in.uv)+draw.uvOffset,
      float(in.color>>24u)/255.0*draw.baseColor.a,draw,motion);
}

vertex IOSMotionVertexOut riosMotionMorphVertex(IOSLandscapeVertexIn in [[stage_in]],
    uint vertexId [[vertex_id]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    constant IOSDeformationConstants& deformation [[buffer(2)]],
    const device IOSMorphLayer* layers [[buffer(3)]],
    const device int* indices [[buffer(4)]], const device float4* samples [[buffer(5)]],
    constant IOSMotionConstants& motion [[buffer(9)]],
    const device IOSMorphLayer* previousLayers [[buffer(10)]]) {
  const float3 local=riosMorphPosition(in.position,vertexId,deformation,layers,indices,samples);
  const float3 previous=riosMorphPosition(in.position,vertexId,deformation,previousLayers,indices,samples);
  const float3 normal=(draw.model*float4(in.normal,0.0)).xyz;
  const float3 oldNormal=(motion.previousModel*float4(in.normal,0.0)).xyz;
  return riosMotionOutput((draw.model*float4(local,1.0)).xyz+normal*deformation.fatness,
      (motion.previousModel*float4(previous,1.0)).xyz+oldNormal*deformation.fatness,
      in.uv+draw.uvOffset,in.color.a*draw.baseColor.a,draw,motion);
}

vertex IOSMotionVertexOut riosMotionInstancedVertex(IOSLandscapeVertexIn in [[stage_in]],
    uint instanceId [[instance_id]],
    constant IOSLandscapeDrawConstants& draw [[buffer(1)]],
    const device IOSGPUInstance* instances [[buffer(6)]],
    constant IOSMotionConstants& motion [[buffer(9)]],
    const device float4x4* previousModels [[buffer(11)]]) {
  const IOSGPUInstance instance=instances[instanceId];
  const float4 local=float4(in.position+in.normal*instance.fatness,1.0);
  return riosMotionOutput((instance.model*local).xyz,(previousModels[instanceId]*local).xyz,
      in.uv+instance.uvOffset,in.color.a*instance.baseColor.a,draw,motion);
}

static float2 riosPreviousMotion(float4 previousClip, float2 currentUV,
    constant IOSMotionConstants& motion) {
  if(previousClip.w<=0.00001)
    return float2(0.0);
  const float2 previousUV=previousClip.xy/previousClip.w*0.5+0.5-motion.jitter.zw/motion.extent.zw;
  return previousUV-currentUV;
}

fragment IOSMotionOutput riosMotionFragment(IOSMotionVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]], sampler textureSampler [[sampler(0)]],
    constant uint& material [[buffer(0)]], constant float& globalReactive [[buffer(1)]],
    constant IOSMotionConstants& motion [[buffer(9)]]) {
  if(material==1u && texture.sample(textureSampler,in.uv).a*in.alpha<0.5)
    discard_fragment();
  const float2 currentUV=(in.position.xy-motion.jitter.xy)/motion.extent.xy;
  return {riosPreviousMotion(in.previousClip,currentUV,motion),
          in.previousClip.w<=0.00001f ? 1.f : globalReactive};
}

struct IOSReactiveOutput { float mask [[color(1)]]; };
fragment IOSReactiveOutput riosReactiveFragment(IOSLandscapeVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]], sampler textureSampler [[sampler(0)]],
    constant uint& material [[buffer(0)]]) {
  const float alpha=texture.sample(textureSampler,in.uv).a*in.color.a;
  if(material==1u && texture.sample(textureSampler,in.uv).a*((in.landscape&4u)!=0 ? 1.0 : in.color.a)<0.5)
    discard_fragment();
  return {material==2u || material==3u ? saturate(alpha) : 1.0};
}

fragment IOSMotionOutput riosSkyMotionFragment(IOSSkyVertexOut in [[stage_in]],
    constant IOSSceneLightingConstants& scene [[buffer(0)]],
    constant float& globalReactive [[buffer(1)]],
    constant IOSMotionConstants& motion [[buffer(9)]]) {
  const float2 uv=in.position.xy/motion.extent.xy;
  const float4 world=scene.inverseViewProjection*float4(uv*2.0-1.0,0.5,1.0);
  const float3 direction=world.xyz/world.w-scene.cameraPosition.xyz;
  const float4 previous=motion.previousViewProjection*float4(direction,0.0);
  return {riosPreviousMotion(previous,uv-motion.jitter.xy/motion.extent.xy,motion),
          previous.w<=0.00001 ? 1.0 : max(globalReactive,0.25)};
}
