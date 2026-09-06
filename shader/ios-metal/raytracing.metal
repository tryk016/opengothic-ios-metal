#include <metal_stdlib>
using namespace metal;
using namespace metal::raytracing;

kernel void riosRayHitMask(instance_acceleration_structure scene [[buffer(0)]],
                          constant float4x4& inverseViewProjection [[buffer(1)]],
                          texture2d<float,access::write> output [[texture(0)]],
                          uint2 pixel [[thread_position_in_grid]]) {
  const uint2 size=uint2(output.get_width(),output.get_height());
  if(any(pixel>=size)) return;
  // Scene vertices flip clip Y before rasterization; inverse VP expects the
  // original scene convention, just like the depth reconstruction pass.
  const float2 ndc=(float2(pixel)+0.5f)/float2(size)*2.f-1.f;
  float4 nearPoint=inverseViewProjection*float4(ndc,0,1);
  float4 farPoint=inverseViewProjection*float4(ndc,1,1);
  const float3 origin=nearPoint.xyz/nearPoint.w;
  const float3 delta=farPoint.xyz/farPoint.w-origin;
  ray query;
  query.origin=origin;
  query.direction=normalize(delta);
  query.min_distance=0;
  query.max_distance=length(delta);
  intersector<triangle_data,instancing> trace;
  const auto hit=trace.intersect(query,scene,0xff);
  output.write(float4(hit.type==intersection_type::none ? 0.f : hit.distance),pixel);
  }

struct RayDebugVertex { float4 position [[position]]; float2 uv; };

vertex RayDebugVertex riosRayDebugVertex(uint index [[vertex_id]]) {
  const float2 uv=float2((index<<1)&2,index&2);
  return {float4(uv*float2(2,-2)+float2(-1,1),0,1),uv};
  }

fragment float4 riosRayDebugFragment(RayDebugVertex in [[stage_in]], texture2d<float> mask [[texture(0)]]) {
  constexpr sampler nearest(coord::normalized,filter::nearest,address::clamp_to_edge);
  return float4(float3(mask.sample(nearest,in.uv).x>0.f ? 1.f : 0.f),1.f);
  }

struct AoConstants {
  float4x4 inverseVP;
  float4x4 viewProjection;
  float4x4 previousViewProjection;
  float4 cameraRadius;
  float4 previousCameraHistory;
  float4 jitter;
  float4 fog;
  uint4 frame;
  };

static float3 worldPosition(depth2d<float,access::read> depth, uint2 pixel, constant AoConstants& c) {
  const float2 uv=(float2(pixel)+.5f)/float2(depth.get_width(),depth.get_height());
  const float4 p=c.inverseVP*float4(uv*2.f-1.f,depth.read(pixel),1.f);
  return p.xyz/p.w;
  }

struct AoSurface { float3 position, normal, direction; float depth; };
static AoSurface surface(depth2d<float,access::read> depth, uint2 pixel, constant AoConstants& c) {
  const uint2 end=uint2(depth.get_width()-1,depth.get_height()-1);
  const uint2 p=min(pixel*2+1,end);
  const uint2 left=uint2(p.x>0 ? p.x-1 : 0,p.y), right=min(p+uint2(1,0),end);
  const uint2 up=uint2(p.x,p.y>0 ? p.y-1 : 0), down=min(p+uint2(0,1),end);
  AoSurface s;
  s.depth=depth.read(p);
  s.position=worldPosition(depth,p,c);
  const float3 dx=(p.x==end.x || (p.x>0 && abs(depth.read(left)-s.depth)<=abs(depth.read(right)-s.depth)))
      ? s.position-worldPosition(depth,left,c) : worldPosition(depth,right,c)-s.position;
  const float3 dy=(p.y==end.y || (p.y>0 && abs(depth.read(up)-s.depth)<=abs(depth.read(down)-s.depth)))
      ? s.position-worldPosition(depth,up,c) : worldPosition(depth,down,c)-s.position;
  const float3 normal=cross(dx,dy);
  const float len=length(normal);
  s.normal=len>1.e-8f ? normal/len : normalize(c.cameraRadius.xyz-s.position);
  if(dot(s.normal,c.cameraRadius.xyz-s.position)<0) s.normal=-s.normal;
  uint seed=(pixel.x+pixel.y*131071u+c.frame.x*524287u)*1664525u+1013904223u;
  const float u=float(seed&0xffffu)/65536.f;
  seed=seed*1664525u+1013904223u;
  const float angle=float(seed&0xffffu)*(2.f*M_PI_F/65536.f);
  const float3 tangent=normalize(cross(abs(s.normal.z)<.9f ? float3(0,0,1) : float3(0,1,0),s.normal));
  s.direction=tangent*(sqrt(u)*cos(angle))+cross(s.normal,tangent)*(sqrt(u)*sin(angle))+s.normal*sqrt(1.f-u);
  return s;
  }

kernel void riosAoTrace(instance_acceleration_structure scene [[buffer(0)]],
                       constant AoConstants& c [[buffer(1)]],
                       depth2d<float,access::read> depth [[texture(0)]],
                       texture2d<float,access::write> output [[texture(1)]],
                       uint2 pixel [[thread_position_in_grid]]) {
  if(pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
  const auto s=surface(depth,pixel,c);
  float visibility=1.f;
  if(s.depth<1.f) {
    ray query;
    query.origin=s.position+s.normal*(c.cameraRadius.w*.002f);
    query.direction=s.direction;
    query.min_distance=c.cameraRadius.w*.001f;
    query.max_distance=c.cameraRadius.w;
    intersector<triangle_data,instancing> trace;
    trace.accept_any_intersection(true);
    const auto hit=trace.intersect(query,scene,0xff);
    visibility=hit.type==intersection_type::none ? 1.f : 0.f;
    }
  output.write(float4(visibility),pixel);
  }

kernel void riosAoRaster(constant AoConstants& c [[buffer(1)]],
                        depth2d<float,access::read> depth [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],
                        uint2 pixel [[thread_position_in_grid]]) {
  if(pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
  const auto s=surface(depth,pixel,c);
  float occlusion=0.f;
  if(s.depth<1.f) for(uint i=1;i<=4;++i) {
    const float3 point=s.position+s.direction*(c.cameraRadius.w*float(i)/4.f);
    const float4 clip=c.viewProjection*float4(point,1.f);
    const float2 uv=clip.xy/clip.w*.5f+.5f;
    if(clip.w<=0 || any(uv<0.f) || any(uv>=1.f)) continue;
    const uint2 sample=uint2(uv*float2(depth.get_width(),depth.get_height()));
    const float3 blocker=worldPosition(depth,sample,c);
    const float3 delta=blocker-s.position;
    const float distance=length(delta);
    if(depth.read(sample)<1.f && distance<c.cameraRadius.w && distance>.001f*c.cameraRadius.w &&
       dot(delta,s.normal)>distance*.1f && depth.read(sample)<clip.z/clip.w)
      occlusion=1.f;
    }
  output.write(float4(1.f-occlusion),pixel);
  }

static float2 aoHistoryUV(float2 rawUV, uint2 fullSize) {
  const float2 pixel=rawUV*float2(fullSize)-.5f;
  // The last representative in an odd extent is clamped to the final full
  // pixel, making that last interval one pixel wide instead of two.
  const float2 odd=float2(fullSize&1u);
  return (pixel+odd*max(pixel-(float2(fullSize)-2.f),0.f))/float2(((fullSize+1u)/2u)*2u);
  }

static float2 historySample(texture2d<float,access::read> history, float2 uv,
                            float expectedDepth, float threshold) {
  const int2 size=int2(history.get_width(),history.get_height());
  const float2 pixel=uv*float2(size)-.5f;
  const int2 base=int2(floor(pixel));
  const float2 fraction=fract(pixel);
  float sum=0.f, weight=0.f;
  for(int y=0;y<2;++y) for(int x=0;x<2;++x) {
    const int2 p=base+int2(x,y);
    if(any(p<0) || any(p>=size)) continue;
    const float2 value=history.read(uint2(p)).xy;
    if(value.y<=0.f || abs(value.y-expectedDepth)>threshold) continue;
    const float w=(x==0 ? 1.f-fraction.x : fraction.x)*(y==0 ? 1.f-fraction.y : fraction.y);
    sum+=value.x*w; weight+=w;
    }
  return float2(weight>0.f ? sum/weight : 1.f,weight);
  }

kernel void riosAoTemporal(constant AoConstants& c [[buffer(1)]],
                          depth2d<float,access::read> depth [[texture(0)]],
                          texture2d<float,access::read> visibility [[texture(1)]],
                          texture2d<float,access::read> motion [[texture(2)]],
                          texture2d<float,access::read> reactive [[texture(3)]],
                          texture2d<float,access::read> previous [[texture(4)]],
                          texture2d<float,access::write> output [[texture(5)]],
                          uint2 pixel [[thread_position_in_grid]]) {
  const uint2 size=uint2(output.get_width(),output.get_height());
  if(any(pixel>=size)) return;
  const uint2 fullSize=uint2(depth.get_width(),depth.get_height());
  const uint2 p=min(pixel*2+1,fullSize-1);
  if(depth.read(p)>=1.f) { output.write(float4(1,0,0,0),pixel); return; }
  const float3 world=worldPosition(depth,p,c);
  const float distance=length(world-c.cameraRadius.xyz);
  float current=visibility.read(pixel).x;
  if(c.frame.y!=0u) {
    const float2 uv=(float2(p)+.5f)/float2(fullSize);
    // Motion excludes jitter; restore the previous raw raster-grid position.
    const float2 previousUV=uv+motion.read(p).xy+c.jitter.xy;
    const float4 previousClip=c.previousViewProjection*float4(world,1.f);
    if(previousClip.w>0.f && previousClip.z>=0.f && previousClip.z<previousClip.w &&
       all(previousUV>=0.f) && all(previousUV<1.f)) {
      const float expectedDepth=length(world-c.previousCameraHistory.xyz);
      const float2 history=historySample(previous,aoHistoryUV(previousUV,fullSize),expectedDepth,
          max(c.cameraRadius.w*.1f,expectedDepth*.005f));
      if(history.y>.1f) {
        float low=current, high=current;
        for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
          const float value=visibility.read(uint2(clamp(int2(pixel)+int2(x,y),int2(0),int2(size)-1))).x;
          low=min(low,value); high=max(high,value);
          }
        const float weight=c.previousCameraHistory.w*(1.f-reactive.read(p).x);
        current=mix(current,clamp(history.x,low,high),weight);
        }
      }
    }
  output.write(float4(current,distance,0,0),pixel);
  }

kernel void riosAoDenoise(constant AoConstants& c [[buffer(1)]],
                         texture2d<float,access::read> history [[texture(0)]],
                         texture2d<float,access::write> output [[texture(1)]],
                         uint2 pixel [[thread_position_in_grid]]) {
  const uint2 size=uint2(output.get_width(),output.get_height());
  if(any(pixel>=size)) return;
  const float2 center=history.read(pixel).xy;
  if(center.y<=0.f) { output.write(float4(1.f),pixel); return; }
  const float threshold=max(c.cameraRadius.w*.2f,center.y*.002f);
  float sum=0.f, weight=0.f;
  for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
    const float2 value=history.read(uint2(clamp(int2(pixel)+int2(x,y),int2(0),int2(size)-1))).xy;
    if(value.y<=0.f) continue;
    const float w=exp2(-abs(value.y-center.y)/threshold)*(x==0 ? 2.f : 1.f)*(y==0 ? 2.f : 1.f);
    sum+=(1.f-value.x)*w;weight+=w;
    }
  output.write(float4(saturate(1.f-sum/weight)),pixel);
  }

fragment float4 riosAoComposite(RayDebugVertex in [[stage_in]],
                               constant AoConstants& c [[buffer(1)]],
                               depth2d<float,access::read> depth [[texture(0)]],
                               texture2d<float,access::read> filtered [[texture(1)]],
                               texture2d<float,access::read> history [[texture(2)]]) {
  const uint2 p=uint2(in.position.xy);
  if(depth.read(p)>=1.f) return float4(1.f);
  const float distance=length(worldPosition(depth,p,c)-c.cameraRadius.xyz);
  const int2 size=int2(filtered.get_width(),filtered.get_height());
  const uint2 fullSize=uint2(depth.get_width(),depth.get_height());
  const float2 sample=aoHistoryUV(in.position.xy/float2(fullSize),fullSize)*float2(size)-.5f;
  const int2 base=int2(floor(sample));
  const float2 fraction=fract(sample);
  float sum=0.f, weight=0.f;
  const float threshold=max(c.cameraRadius.w*.2f,distance*.002f);
  for(int y=0;y<2;++y) for(int x=0;x<2;++x) {
    const int2 q=clamp(base+int2(x,y),int2(0),size-1);
    const float oldDepth=history.read(uint2(q)).y;
    if(oldDepth<=0.f) continue;
    const float w=(x==0 ? 1.f-fraction.x : fraction.x)*(y==0 ? 1.f-fraction.y : fraction.y)*
                  exp2(-abs(oldDepth-distance)/threshold);
    sum+=(1.f-filtered.read(uint2(q)).x)*w;weight+=w;
    }
  const float occlusion=weight>0.f ? saturate(sum/weight) : 0.f;
  float fade=1.f-smoothstep(c.fog.z*.75f,c.fog.z,distance);
  if(c.fog.y>c.fog.x) fade*=1.f-smoothstep(c.fog.x,c.fog.y,distance);
  return float4(float3(1.f-c.fog.w*fade*occlusion),1.f);
  }
