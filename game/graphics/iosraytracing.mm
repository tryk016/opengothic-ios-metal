#if defined(OPENGOTHIC_RENDERER_IOS_RAYTRACING)
#include "iosraytracing.h"

#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <stdexcept>
#include <tuple>
#include <vector>

namespace {
struct Native final {
  id value = nil;
  Native() = default;
  explicit Native(id value):value(value) { if(value==nil) throw std::bad_alloc(); }
  ~Native() { [value release]; }
  Native(Native&& other) noexcept:value(other.value) { other.value=nil; }
  Native& operator=(Native&& other) noexcept {
    std::swap(value,other.value);
    return *this;
    }
  Native(const Native&) = delete;
  Native& operator=(const Native&) = delete;
  };

id<MTLBuffer> reserve(id<MTLDevice> device, Native& storage, size_t size, bool shared) {
  auto buffer=(id<MTLBuffer>)storage.value;
  if(buffer==nil || buffer.length<size) {
    storage=Native([device newBufferWithLength:size options:shared ?
        MTLResourceStorageModeShared : MTLResourceStorageModePrivate]);
    buffer=(id<MTLBuffer>)storage.value;
    }
  return buffer;
  }

struct Blas final {
  Native structure;
  uint64_t compactedSize = 0;
  bool compacted = false;
  };
struct Entry final { std::shared_ptr<Blas> current; };
using Key=std::tuple<uint64_t,size_t,size_t,size_t>;
struct Build final {
  std::shared_ptr<Blas> blas;
  Native descriptor;
  size_t scratchSize = 0;
  Native sourceIndices, alignedIndices;
  size_t indexOffset = 0, indexBytes = 0;
  };
struct Compaction final { std::shared_ptr<Blas> source, destination; };
struct Publication final { Entry* entry; std::shared_ptr<Blas> version; };

struct History final {
  uint64_t generation = 0, sequence = 0, time = 0;
  uint32_t index = 0, sample = 0;
  bool rays = false;
  };
struct alignas(16) AoConstants final {
  IOSMatrix4x4 inverseVP, viewProjection, previousViewProjection;
  IOSFloat4 cameraRadius, previousCameraHistory, jitter, fog;
  std::array<uint32_t,4> frame={};
  };
static_assert(sizeof(AoConstants)==272);
}

struct IOSRayTracing::Impl final {
  id<MTLDevice> device = nil;
  bool supported = false;
  uint64_t generation = 0;
  std::map<Key,Entry> cache;
  Native debugMask, tracePipeline, debugPipeline;
  std::array<Native,4> aoPipelines;
  Native aoComposite, aoRaw, aoFiltered;
  std::array<Native,2> aoHistory;
  History history;
  };

struct IOSRayTracing::Frame::Impl final {
  // Reused scratch pool belongs to the existing frame context. Separate
  // buffers let Metal overlap small BLAS builds without reusing their scratch.
  std::array<Native,4> scratch;
  Native query, instances, tlas, tlasDescriptor;
  std::vector<Build> builds;
  std::vector<Compaction> compactions;
  std::vector<Publication> publications;
  std::vector<std::shared_ptr<Blas>> blases;
  uint32_t instanceCount = 0;
  bool submitted = false, encoded = false, ready = false;
  IOSRayTracing::Impl* historyOwner = nullptr;
  History pendingHistory;
  std::array<Native,7> historyTextures;
  };

IOSRayTracing::Frame::Frame() = default;
IOSRayTracing::Frame::~Frame() = default;
IOSRayTracing::Frame::Frame(Frame&&) noexcept = default;
IOSRayTracing::Frame& IOSRayTracing::Frame::operator=(Frame&&) noexcept = default;

void IOSRayTracing::Frame::markSubmitted() noexcept {
  if(impl==nullptr || !impl->encoded) return;
  impl->submitted=true;
  // Entries were allocated during prepare, before the native submission.
  for(const auto& publication:impl->publications)
    publication.entry->current=publication.version;
  if(impl->historyOwner!=nullptr)
    impl->historyOwner->history=impl->pendingHistory;
  }

void IOSRayTracing::Frame::completeConfirmed() noexcept {
  if(impl==nullptr || !impl->submitted) return;
  if(!impl->builds.empty()) {
    const auto* sizes=static_cast<const uint64_t*>(((id<MTLBuffer>)impl->query.value).contents);
    for(size_t i=0;i<impl->builds.size();++i)
      impl->builds[i].blas->compactedSize=sizes[i];
    }
  impl->submitted=false;
  }

bool IOSRayTracing::Frame::ready() const noexcept { return impl!=nullptr && impl->ready; }
uint32_t IOSRayTracing::Frame::instanceCount() const noexcept { return impl==nullptr ? 0 : impl->instanceCount; }
uint32_t IOSRayTracing::Frame::buildCount() const noexcept { return impl==nullptr ? 0 : uint32_t(impl->builds.size()); }
uint32_t IOSRayTracing::Frame::compactionCount() const noexcept { return impl==nullptr ? 0 : uint32_t(impl->compactions.size()); }

IOSRayTracing::IOSRayTracing(MTL::Device* device):impl(std::make_unique<Impl>()) {
  impl->device=(id<MTLDevice>)(void*)device;
  impl->supported=impl->device.supportsRaytracing;
  }
IOSRayTracing::~IOSRayTracing() = default;
bool IOSRayTracing::supported() const noexcept { return impl->supported; }
void IOSRayTracing::clearAfterConfirmedIdle() noexcept {
  impl->cache.clear();
  impl->generation=0;
  impl->debugMask={};
  impl->aoRaw={}; impl->aoFiltered={}; impl->aoHistory={};
  impl->history={};
  }

void IOSRayTracing::prepare(Frame& frame, uint64_t generation, std::span<const Geometry> geometry) {
  if(frame.impl==nullptr) frame.impl=std::make_unique<Frame::Impl>();
  auto& out=*frame.impl;
  out.builds.clear(); out.compactions.clear(); out.publications.clear(); out.blases.clear();
  out.tlas={}; out.tlasDescriptor={};
  out.submitted=false; out.encoded=false; out.ready=false; out.instanceCount=0;
  out.historyOwner=nullptr; out.historyTextures={};
  if(!supported()) return; // No AS, descriptor, or scratch allocation on unsupported devices.
  if(impl->generation!=0 && impl->generation!=generation)
    throw std::logic_error("RendererIOS RT world change requires confirmed idle");
  impl->generation=generation;
  std::vector<MTLAccelerationStructureInstanceDescriptor> instances;
  std::map<Blas*,uint32_t> indices;
  size_t triangles=0;
  bool complete=true;
  auto device=impl->device;
  for(const auto& original:geometry) {
    // Large landscape ranges share vertices but become bounded BLAS chunks.
    constexpr size_t ChunkIndices=16384*3;
    for(size_t first=0;first<original.indexCount;first+=ChunkIndices) {
      auto source=original;
      source.firstIndex+=first;
      source.indexCount=std::min(ChunkIndices,original.indexCount-first);
      auto& entry=impl->cache[{source.mesh,source.firstIndex,source.indexCount,source.stride}];
      auto blas=entry.current;
      if(const auto staged=std::find_if(out.publications.begin(),out.publications.end(),
           [&](const auto& p) { return p.entry==&entry; }); staged!=out.publications.end())
        blas=staged->version;
      if(blas==nullptr) {
        if(out.builds.size()>=16 || triangles+source.indexCount/3>65536) {
          complete=false;
          continue;
          }
        auto desc=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
        desc.vertexBuffer=(id<MTLBuffer>)(void*)source.vertices;
        desc.vertexStride=source.stride;
        desc.vertexFormat=MTLAttributeFormatFloat3;
        desc.indexBuffer=(id<MTLBuffer>)(void*)source.indices;
        desc.indexBufferOffset=source.firstIndex*sizeof(uint32_t);
        desc.indexType=MTLIndexTypeUInt32;
        desc.triangleCount=source.indexCount/3;
        desc.opaque=YES;
        Build build;
        // AS index offsets have stricter alignment than raster draws. Stage only
        // the affected range at offset zero; never silently omit its triangles.
        if(desc.indexBufferOffset%256!=0) {
          build.indexOffset=desc.indexBufferOffset;
          build.indexBytes=source.indexCount*sizeof(uint32_t);
          build.sourceIndices=Native([desc.indexBuffer retain]);
          build.alignedIndices=Native([device newBufferWithLength:build.indexBytes options:MTLResourceStorageModePrivate]);
          desc.indexBuffer=(id<MTLBuffer>)build.alignedIndices.value;
          desc.indexBufferOffset=0;
          }
        auto primitive=[MTLPrimitiveAccelerationStructureDescriptor descriptor];
        primitive.geometryDescriptors=@[desc];
        const auto sizes=[device accelerationStructureSizesWithDescriptor:primitive];
        blas=std::make_shared<Blas>();
        blas->structure=Native([device newAccelerationStructureWithSize:sizes.accelerationStructureSize]);
        build.blas=blas;
        build.descriptor=Native([primitive retain]);
        build.scratchSize=sizes.buildScratchBufferSize;
        out.builds.push_back(std::move(build));
        out.publications.push_back({&entry,blas});
        triangles+=desc.triangleCount;
        }
      else if(!blas->compacted && blas->compactedSize!=0 && out.compactions.size()<16) {
        auto compact=std::make_shared<Blas>();
        compact->structure=Native([device newAccelerationStructureWithSize:blas->compactedSize]);
        compact->compacted=true;
        out.compactions.push_back({blas,compact});
        out.publications.push_back({&entry,compact});
        blas=std::move(compact);
        }
      const auto [index,inserted]=indices.try_emplace(blas.get(),uint32_t(out.blases.size()));
      if(inserted) out.blases.push_back(blas);
      MTLAccelerationStructureInstanceDescriptor instance={};
      for(size_t c=0;c<4;++c)
        for(size_t r=0;r<3;++r)
          reinterpret_cast<float*>(&instance.transformationMatrix)[c*3+r]=source.transform.at(r,c);
      instance.options=MTLAccelerationStructureInstanceOptionOpaque;
      instance.mask=0xff;
      instance.accelerationStructureIndex=index->second;
      instances.push_back(instance);
    }
    }
  std::array<size_t,4> scratchSize={};
  for(size_t i=0;i<out.builds.size();++i)
    scratchSize[i%4]=std::max(scratchSize[i%4],out.builds[i].scratchSize);
  if(!out.builds.empty())
    reserve(device,out.query,out.builds.size()*sizeof(uint64_t),true);
  if(complete && !instances.empty()) {
    auto buffer=reserve(device,out.instances,instances.size()*sizeof(instances[0]),true);
    std::memcpy(buffer.contents,instances.data(),instances.size()*sizeof(instances[0]));
    auto desc=[MTLInstanceAccelerationStructureDescriptor descriptor];
    desc.instanceDescriptorBuffer=buffer;
    desc.instanceCount=instances.size();
    auto structures=[NSMutableArray arrayWithCapacity:out.blases.size()];
    for(const auto& blas:out.blases) [structures addObject:blas->structure.value];
    desc.instancedAccelerationStructures=structures;
    const auto sizes=[device accelerationStructureSizesWithDescriptor:desc];
    scratchSize[0]=std::max(scratchSize[0],sizes.buildScratchBufferSize);
    out.tlas=Native([device newAccelerationStructureWithSize:sizes.accelerationStructureSize]);
    out.tlasDescriptor=Native([desc retain]);
    out.instanceCount=uint32_t(instances.size());
    out.ready=true;
    }
  for(size_t i=0;i<4;++i)
    if(scratchSize[i]!=0) reserve(device,out.scratch[i],scratchSize[i],false);
  }

bool IOSRayTracing::encodeBuilds(Frame& frame, MTL::CommandBuffer* native) {
  if(frame.impl==nullptr) return true;
  auto& data=*frame.impl;
  auto command=(id<MTLCommandBuffer>)(void*)native;
  if(std::any_of(data.builds.begin(),data.builds.end(),[](const auto& b) { return b.alignedIndices.value!=nil; })) {
    auto encoder=[command blitCommandEncoder];
    if(encoder==nil) return false;
    @try {
      encoder.label=@"RendererIOS RT index alignment";
      for(const auto& build:data.builds)
        if(build.alignedIndices.value!=nil)
          [encoder copyFromBuffer:(id<MTLBuffer>)build.sourceIndices.value sourceOffset:build.indexOffset
              toBuffer:(id<MTLBuffer>)build.alignedIndices.value destinationOffset:0 size:build.indexBytes];
      }
    @finally { [encoder endEncoding]; }
    }
  if(!data.builds.empty() || !data.compactions.empty()) {
    auto encoder=[command accelerationStructureCommandEncoder];
    if(encoder==nil) return false;
    @try {
      encoder.label=@"RendererIOS static BLAS build and compaction";
      for(size_t i=0;i<data.builds.size();++i) {
        const auto& build=data.builds[i];
        [encoder buildAccelerationStructure:(id<MTLAccelerationStructure>)build.blas->structure.value
            descriptor:(MTLAccelerationStructureDescriptor*)build.descriptor.value
            scratchBuffer:(id<MTLBuffer>)data.scratch[i%4].value scratchBufferOffset:0];
        [encoder writeCompactedAccelerationStructureSize:(id<MTLAccelerationStructure>)build.blas->structure.value
            toBuffer:(id<MTLBuffer>)data.query.value offset:i*sizeof(uint64_t) sizeDataType:MTLDataTypeULong];
        }
      for(const auto& compact:data.compactions)
        [encoder copyAndCompactAccelerationStructure:(id<MTLAccelerationStructure>)compact.source->structure.value
            toAccelerationStructure:(id<MTLAccelerationStructure>)compact.destination->structure.value];
      }
    @finally { [encoder endEncoding]; }
    }
  if(data.ready) {
    auto encoder=[command accelerationStructureCommandEncoder];
    if(encoder==nil) return false;
    @try {
      encoder.label=@"RendererIOS frame TLAS build";
      for(const auto& blas:data.blases)
        [encoder useResource:(id<MTLResource>)blas->structure.value usage:MTLResourceUsageRead];
      [encoder buildAccelerationStructure:(id<MTLAccelerationStructure>)data.tlas.value
          descriptor:(MTLAccelerationStructureDescriptor*)data.tlasDescriptor.value
          scratchBuffer:(id<MTLBuffer>)data.scratch[0].value scratchBufferOffset:0];
      }
    @finally { [encoder endEncoding]; }
    }
  data.encoded=true;
  return true;
  }

void IOSRayTracing::bind(const Frame& frame, MTL::ComputeCommandEncoder* native, unsigned index) const {
  auto encoder=(id<MTLComputeCommandEncoder>)(void*)native;
  const auto& data=*frame.impl;
  [encoder setAccelerationStructure:(id<MTLAccelerationStructure>)data.tlas.value atBufferIndex:index];
  for(const auto& blas:data.blases)
    [encoder useResource:(id<MTLResource>)blas->structure.value usage:MTLResourceUsageRead];
  }

bool IOSRayTracing::encodeDebug(const Frame& frame, MTL::CommandBuffer* native, MTL::Texture* target,
                                const IOSCameraState& camera) try {
  if(!frame.ready()) return true;
  auto command=(id<MTLCommandBuffer>)(void*)native;
  auto color=(id<MTLTexture>)(void*)target;
  if(impl->tracePipeline.value==nil) {
    NSURL* url=[[NSBundle mainBundle] URLForResource:@"RendererIOSRayTracing" withExtension:@"metallib"];
    if(url==nil) return false;
    NSError* error=nil;
    Native library([impl->device newLibraryWithURL:url error:&error]);
    Native trace([(id<MTLLibrary>)library.value newFunctionWithName:@"riosRayHitMask"]);
    Native vertex([(id<MTLLibrary>)library.value newFunctionWithName:@"riosRayDebugVertex"]);
    Native fragment([(id<MTLLibrary>)library.value newFunctionWithName:@"riosRayDebugFragment"]);
    auto desc=[MTLRenderPipelineDescriptor new];
    desc.vertexFunction=(id<MTLFunction>)vertex.value;
    desc.fragmentFunction=(id<MTLFunction>)fragment.value;
    desc.colorAttachments[0].pixelFormat=color.pixelFormat;
    Native renderDesc(desc);
    Native debug([impl->device newRenderPipelineStateWithDescriptor:desc error:&error]);
    Native compute([impl->device newComputePipelineStateWithFunction:(id<MTLFunction>)trace.value error:&error]);
    impl->debugPipeline=std::move(debug);
    impl->tracePipeline=std::move(compute);
    }
  auto mask=(id<MTLTexture>)impl->debugMask.value;
  const NSUInteger width=(color.width+1)/2, height=(color.height+1)/2;
  if(mask==nil || mask.width!=width || mask.height!=height) {
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
        width:width height:height mipmapped:NO];
    desc.storageMode=MTLStorageModePrivate;
    desc.usage=MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    impl->debugMask=Native([impl->device newTextureWithDescriptor:desc]);
    mask=(id<MTLTexture>)impl->debugMask.value;
    }
  auto compute=[command computeCommandEncoder];
  if(compute==nil) return false;
  @try {
    compute.label=@"RendererIOS RT0 hit mask";
    [compute setComputePipelineState:(id<MTLComputePipelineState>)impl->tracePipeline.value];
    bind(frame,(MTL::ComputeCommandEncoder*)(void*)compute,0);
    [compute setBytes:&camera.inverseViewProjection length:sizeof(camera.inverseViewProjection) atIndex:1];
    [compute setTexture:mask atIndex:0];
    [compute dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    }
  @finally { [compute endEncoding]; }
  auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=color;
  pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
  pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  auto render=[command renderCommandEncoderWithDescriptor:pass];
  if(render==nil) return false;
  @try {
    render.label=@"RendererIOS RT0 debug visualization";
    [render setRenderPipelineState:(id<MTLRenderPipelineState>)impl->debugPipeline.value];
    [render setFragmentTexture:mask atIndex:0];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
  @finally { [render endEncoding]; }
  return true;
  }
catch(...) { return false; }

bool IOSRayTracing::encodeAmbientOcclusion(Frame& frame, MTL::CommandBuffer* native, MTL::Texture* target,
                                           MTL::Texture* nativeDepth, MTL::Texture* nativeMotion,
                                           MTL::Texture* nativeReactive, const IOSSceneSnapshot& snapshot) try {
  auto& state=*impl;
  auto device=state.device;
  auto command=(id<MTLCommandBuffer>)(void*)native;
  auto color=(id<MTLTexture>)(void*)target;
  auto depth=(id<MTLTexture>)(void*)nativeDepth;
  auto motion=(id<MTLTexture>)(void*)nativeMotion;
  auto reactive=(id<MTLTexture>)(void*)nativeReactive;
  if(state.aoComposite.value==nil) {
    NSURL* url=[[NSBundle mainBundle] URLForResource:@"RendererIOSRayTracing" withExtension:@"metallib"];
    if(url==nil) return false;
    NSError* error=nil;
    Native library([device newLibraryWithURL:url error:&error]);
    const std::array<NSString*,4> names={@"riosAoTrace",@"riosAoRaster",@"riosAoTemporal",@"riosAoDenoise"};
    for(size_t i=0;i<names.size();++i) {
      // Unsupported devices never create an RT pipeline or acceleration structure.
      if(i==0 && !supported()) continue;
      Native function([(id<MTLLibrary>)library.value newFunctionWithName:names[i]]);
      state.aoPipelines[i]=Native([device newComputePipelineStateWithFunction:(id<MTLFunction>)function.value error:&error]);
      }
    Native vertex([(id<MTLLibrary>)library.value newFunctionWithName:@"riosRayDebugVertex"]);
    Native fragment([(id<MTLLibrary>)library.value newFunctionWithName:@"riosAoComposite"]);
    Native descriptor([MTLRenderPipelineDescriptor new]);
    auto desc=(MTLRenderPipelineDescriptor*)descriptor.value;
    desc.vertexFunction=(id<MTLFunction>)vertex.value;
    desc.fragmentFunction=(id<MTLFunction>)fragment.value;
    auto attachment=desc.colorAttachments[0];
    attachment.pixelFormat=color.pixelFormat;
    attachment.blendingEnabled=YES;
    attachment.sourceRGBBlendFactor=MTLBlendFactorZero;
    attachment.destinationRGBBlendFactor=MTLBlendFactorSourceColor;
    attachment.sourceAlphaBlendFactor=MTLBlendFactorZero;
    attachment.destinationAlphaBlendFactor=MTLBlendFactorOne;
    state.aoComposite=Native([device newRenderPipelineStateWithDescriptor:desc error:&error]);
    }
  const NSUInteger width=(depth.width+1)/2, height=(depth.height+1)/2;
  auto raw=(id<MTLTexture>)state.aoRaw.value;
  if(raw==nil || raw.width!=width || raw.height!=height) {
    const auto texture=[&](MTLPixelFormat format) {
      auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
      desc.storageMode=MTLStorageModePrivate;
      desc.usage=MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      return Native([device newTextureWithDescriptor:desc]);
      };
    Native aoRaw=texture(MTLPixelFormatR16Float), filtered=texture(MTLPixelFormatR16Float);
    std::array<Native,2> history={texture(MTLPixelFormatRG32Float),texture(MTLPixelFormatRG32Float)};
    state.aoRaw=std::move(aoRaw);state.aoFiltered=std::move(filtered);state.aoHistory=std::move(history);
    state.history={};
    }
  if(frame.impl==nullptr) frame.impl=std::make_unique<Frame::Impl>();
  auto& data=*frame.impl;
  const bool rays=frame.ready();
  const auto& current=snapshot.currentCamera;
  const auto& previous=snapshot.previousCamera;
  const auto& accepted=state.history;
  const float dx=current.position.x-previous.position.x;
  const float dy=current.position.y-previous.position.y;
  const float dz=current.position.z-previous.position.z;
  float directionDot=0.f;
  for(size_t axis=0;axis<3;++axis) directionDot+=current.view.at(2,axis)*previous.view.at(2,axis);
  const bool projectionCut=std::abs(current.projection.at(0,0)-previous.projection.at(0,0))>
      std::abs(previous.projection.at(0,0))*.1f ||
      std::abs(current.projection.at(1,1)-previous.projection.at(1,1))>std::abs(previous.projection.at(1,1))*.1f;
  const bool historyValid=motion!=nil && reactive!=nil && snapshot.historyValid &&
      accepted.generation==snapshot.generation.value && accepted.sequence+1==snapshot.sequence.value &&
      accepted.rays==rays && snapshot.sceneTimeMs>=accepted.time && snapshot.sceneTimeMs-accepted.time<=250 &&
      dx*dx+dy*dy+dz*dz<=200.f*200.f && directionDot>=.5f && !projectionCut;
  const uint32_t next=1u-accepted.index;
  AoConstants c={};
  c.inverseVP=current.inverseViewProjection;
  c.viewProjection=current.viewProjection;
  c.previousViewProjection=previous.viewProjection;
  c.cameraRadius={current.position.x,current.position.y,current.position.z,100.f};
  c.previousCameraHistory={previous.position.x,previous.position.y,previous.position.z,.85f};
  if(historyValid) c.jitter={previous.jitter.x/float(previous.viewport.width)-current.jitter.x/float(current.viewport.width),
                            previous.jitter.y/float(previous.viewport.height)-current.jitter.y/float(current.viewport.height),0,0};
  c.fog={snapshot.currentSky.fogNear,snapshot.currentSky.fogFar,10000.f,.35f};
  c.frame={historyValid ? accepted.sample : 0u,historyValid ? 1u : 0u,0,0};
  // Invalid history still needs valid, frame-owned shader arguments.
  if(motion==nil) motion=(id<MTLTexture>)state.aoRaw.value;
  if(reactive==nil) reactive=(id<MTLTexture>)state.aoRaw.value;
  const std::array<id,7> resources={state.aoRaw.value,state.aoFiltered.value,
      state.aoHistory[accepted.index].value,state.aoHistory[next].value,depth,motion,reactive};
  for(size_t i=0;i<resources.size();++i) data.historyTextures[i]=Native([resources[i] retain]);
  const auto dispatch=[&](size_t pipeline, const auto& bindInputs) {
    auto encoder=[command computeCommandEncoder];
    if(encoder==nil) return false;
    @try {
      [encoder setComputePipelineState:(id<MTLComputePipelineState>)state.aoPipelines[pipeline].value];
      [encoder setBytes:&c length:sizeof(c) atIndex:1];
      bindInputs(encoder);
      [encoder dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
      }
    @finally { [encoder endEncoding]; }
    return true;
    };
  if(!dispatch(rays ? 0u : 1u,[&](id<MTLComputeCommandEncoder> encoder) {
       encoder.label=rays ? @"RendererIOS RTAO" : @"RendererIOS screen-space AO fallback";
       if(rays) bind(frame,(MTL::ComputeCommandEncoder*)(void*)encoder,0);
       [encoder setTexture:depth atIndex:0];[encoder setTexture:(id<MTLTexture>)state.aoRaw.value atIndex:1];
       })) return false;
  if(!dispatch(2,[&](id<MTLComputeCommandEncoder> encoder) {
       encoder.label=@"RendererIOS AO temporal accumulation";
       [encoder setTexture:depth atIndex:0];[encoder setTexture:(id<MTLTexture>)state.aoRaw.value atIndex:1];
       [encoder setTexture:motion atIndex:2];
       [encoder setTexture:reactive atIndex:3];
       [encoder setTexture:(id<MTLTexture>)state.aoHistory[accepted.index].value atIndex:4];
       [encoder setTexture:(id<MTLTexture>)state.aoHistory[next].value atIndex:5];
       })) return false;
  if(!dispatch(3,[&](id<MTLComputeCommandEncoder> encoder) {
       encoder.label=@"RendererIOS AO depth-aware denoise";
       [encoder setTexture:(id<MTLTexture>)state.aoHistory[next].value atIndex:0];
       [encoder setTexture:(id<MTLTexture>)state.aoFiltered.value atIndex:1];
       })) return false;
  auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=color;
  pass.colorAttachments[0].loadAction=MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  auto render=[command renderCommandEncoderWithDescriptor:pass];
  if(render==nil) return false;
  @try {
    render.label=@"RendererIOS AO composite";
    [render setRenderPipelineState:(id<MTLRenderPipelineState>)state.aoComposite.value];
    [render setFragmentBytes:&c length:sizeof(c) atIndex:1];
    [render setFragmentTexture:depth atIndex:0];
    [render setFragmentTexture:(id<MTLTexture>)state.aoFiltered.value atIndex:1];
    [render setFragmentTexture:(id<MTLTexture>)state.aoHistory[next].value atIndex:2];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
  @finally { [render endEncoding]; }
  data.historyOwner=&state;
  data.pendingHistory={snapshot.generation.value,snapshot.sequence.value,snapshot.sceneTimeMs,next,c.frame[0]+1u,rays};
  data.encoded=true;
  return true;
  }
catch(...) { return false; }

#endif
