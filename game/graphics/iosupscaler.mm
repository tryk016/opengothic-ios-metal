#include "iosupscaler.h"
#include "iosfeaturepolicy.h"
#include "ioslandscapeshaderabi.h"

#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/CommandBuffer>
#include <Tempest/MetalApi>
#include <Tempest/StorageImage>
#include <Tempest/Log>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR
#import <MetalFX/MetalFX.h>
#endif

#include <algorithm>
#include <array>
#include <cmath>

namespace {
const char* modeName(IOSUpscalerMode mode) {
  constexpr const char* names[] = {"auto","temporal","spatial","fsr1","native"};
  return names[uint8_t(mode)];
  }
float halton(uint32_t index, uint32_t base) {
  float result=0.f, weight=1.f;
  while(index>0) { weight/=float(base); result+=weight*float(index%base); index/=base; }
  return result;
  }
}

struct IOSUpscaler::Impl final {
  explicit Impl(Tempest::Device& owner) : owner(owner) {
    native = (id<MTLDevice>)(void*)Tempest::MetalApi::borrowDevice(owner).get();
    @autoreleasepool {
      NSURL* url = [[NSBundle mainBundle] URLForResource:@"RendererIOS" withExtension:@"metallib"];
      NSError* error=nil;
      id<MTLLibrary> library = url!=nil ? [native newLibraryWithURL:url error:&error] : nil;
      NSArray<NSString*>* names = @[@"riosFsrPrepare",@"riosFsrEasu",@"riosFsrRcas"];
      for(NSUInteger i=0; i<names.count; ++i) {
        id<MTLFunction> function=[library newFunctionWithName:names[i]];
        fsr[i]=function!=nil ? [native newComputePipelineStateWithFunction:function error:&error] : nil;
        [function release];
        }
      id<MTLFunction> vertex=[library newFunctionWithName:@"riosToneResolveVertex"];
      id<MTLFunction> fragment=[library newFunctionWithName:@"riosSceneCopyFragment"];
      if(vertex!=nil && fragment!=nil) {
        MTLRenderPipelineDescriptor* desc=[[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction=vertex; desc.fragmentFunction=fragment;
        desc.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        copyPipeline=[native newRenderPipelineStateWithDescriptor:desc error:&error];
        [desc release];
        }
      [vertex release]; [fragment release];
      [library release];
      }
    }
  ~Impl() {
    releaseScalers();
    for(id pipeline:fsr) [pipeline release];
    [copyPipeline release];
    }
  void releaseScalers() {
#if !TARGET_OS_SIMULATOR
    [temporal release]; temporal=nil;
    [spatial release]; spatial=nil;
#endif
    }
  bool makeSpatial() {
#if !TARGET_OS_SIMULATOR
    if(!spatialEligible) return false;
    @try {
      MTLFXSpatialScalerDescriptor* desc=[[MTLFXSpatialScalerDescriptor alloc] init];
    desc.inputWidth=NSUInteger(input.w); desc.inputHeight=NSUInteger(input.h);
    desc.outputWidth=NSUInteger(size.w); desc.outputHeight=NSUInteger(size.h);
    desc.colorTextureFormat=MTLPixelFormatRG11B10Float; desc.outputTextureFormat=MTLPixelFormatRG11B10Float;
    desc.colorProcessingMode=MTLFXSpatialScalerColorProcessingModeHDR;
    @try { spatial=[desc newSpatialScalerWithDevice:native]; }
    @finally { [desc release]; }
    return spatial!=nil;
      }
    @catch(NSException*) { return false; }
#else
    return false;
#endif
    }
  bool makeTemporal() {
#if !TARGET_OS_SIMULATOR
    if(!temporalEligible) return false;
    @try {
    if(@available(iOS 17.4,macOS 14.4,*)) {
      MTLFXTemporalScalerDescriptor* desc=[[MTLFXTemporalScalerDescriptor alloc] init];
      desc.inputWidth=NSUInteger(input.w); desc.inputHeight=NSUInteger(input.h);
      desc.outputWidth=NSUInteger(size.w); desc.outputHeight=NSUInteger(size.h);
      desc.colorTextureFormat=MTLPixelFormatRG11B10Float; desc.outputTextureFormat=MTLPixelFormatRG11B10Float;
      desc.depthTextureFormat=MTLPixelFormatDepth32Float; desc.motionTextureFormat=MTLPixelFormatRG16Float;
      desc.reactiveMaskTextureEnabled=YES; desc.reactiveMaskTextureFormat=MTLPixelFormatR8Unorm;
      desc.autoExposureEnabled=YES;
      @try { temporal=[desc newTemporalScalerWithDevice:native]; }
      @finally { [desc release]; }
      return temporal!=nil;
      }
      }
    @catch(NSException*) { return false; }
#endif
    return false;
    }
  bool makeFsr() {
    if(copyPipeline==nil || std::any_of(fsr.begin(),fsr.end(),[](id p) { return p==nil; })) return false;
    fsrInput=owner.image2d(Tempest::TextureFormat::R11G11B10UF,uint32_t(input.w),uint32_t(input.h));
    fsrIntermediate=owner.image2d(Tempest::TextureFormat::R11G11B10UF,uint32_t(size.w),uint32_t(size.h));
    return !fsrInput.isEmpty() && !fsrIntermediate.isEmpty();
    }
  id<MTLTexture> texture(const Tempest::StorageImage& image) const {
    return (id<MTLTexture>)(void*)Tempest::MetalApi::borrowTexture(owner,
        Tempest::textureCast<const Tempest::Texture2d&>(image)).get();
    }
  void failEncode() {
    encodeFailed=true;
    failedModes|=uint8_t(1u<<uint8_t(mode));
    log("encode-failed-reconfigure-next-frame");
    }
  void log(const char* reason) const {
    Tempest::Log::i("RendererIOS upscaler: requested=",modeName(requested.mode),
        " active=",modeName(mode)," input=",input.w,"x",input.h,
        " output=",size.w,"x",size.h," fallback=",reason);
    }
  Tempest::Device& owner;
  id<MTLDevice> native=nil;
  IOSUpscalerSettings requested;
  IOSUpscalerMode mode=IOSUpscalerMode::Native;
  Tempest::Size input, size;
  bool spatialEligible=false, temporalEligible=false, reset=true, encodeFailed=false;
  uint8_t failedModes=0;
  uint32_t sample=0;
  uint64_t previousTime=0;
  Tempest::StorageImage result, fsrInput, fsrIntermediate;
  std::array<id<MTLComputePipelineState>,3> fsr{};
  id<MTLRenderPipelineState> copyPipeline=nil;
#if !TARGET_OS_SIMULATOR
  id<MTLFXSpatialScaler> spatial=nil;
  id<MTLFXTemporalScaler> temporal=nil;
#endif
  };

IOSUpscaler::IOSUpscaler(Tempest::Device& device) : impl(std::make_unique<Impl>(device)) {}
IOSUpscaler::~IOSUpscaler() = default;

void IOSUpscaler::configure(IOSUpscalerSettings settings, Tempest::Size size, const IOSDeviceFacts& facts, bool motionAvailable) {
  auto& s=*impl;
  s.releaseScalers();
  s.result={}; s.fsrInput={}; s.fsrIntermediate={};
  if(settings!=s.requested) s.failedModes=0;
  s.encodeFailed=false;
  s.requested=settings; s.size=size; s.input=size; s.mode=IOSUpscalerMode::Native;
  s.reset=true; s.sample=0; s.previousTime=0;
  if(settings.mode==IOSUpscalerMode::Native || settings.scale>=1.f) { s.log("none"); return; }
  s.input={std::max(1,int(float(size.w)*settings.scale)),std::max(1,int(float(size.h)*settings.scale))};
  s.spatialEligible=iosEvaluateFeaturePolicy(facts,{IOSFeatureId::MetalFxSpatial,true,false}).eligible;
  s.temporalEligible=motionAvailable && iosEvaluateFeaturePolicy(facts,{IOSFeatureId::MetalFxTemporal,true,false}).eligible;
  const bool requestTemporal=settings.mode==IOSUpscalerMode::Auto || settings.mode==IOSUpscalerMode::Temporal;
  const auto permitted=[&](IOSUpscalerMode mode) { return (s.failedModes&(1u<<uint8_t(mode)))==0; };
  @try {
    try {
      s.result=s.owner.image2d(Tempest::TextureFormat::R11G11B10UF,uint32_t(size.w),uint32_t(size.h));
      if(!s.result.isEmpty()) {
        if(requestTemporal && permitted(IOSUpscalerMode::Temporal) && s.makeTemporal()) s.mode=IOSUpscalerMode::Temporal;
        else if(settings.mode!=IOSUpscalerMode::Fsr1 && permitted(IOSUpscalerMode::Spatial) && s.makeSpatial()) s.mode=IOSUpscalerMode::Spatial;
        else if(permitted(IOSUpscalerMode::Fsr1) && s.makeFsr()) s.mode=IOSUpscalerMode::Fsr1;
        }
      }
    catch(...) { s.mode=IOSUpscalerMode::Native; }
    }
  @catch(NSException*) { s.mode=IOSUpscalerMode::Native; }
  if(s.mode==IOSUpscalerMode::Native) {
    s.input=size; s.result={}; s.fsrInput={}; s.fsrIntermediate={}; s.releaseScalers();
    }
  s.log(s.mode==settings.mode || (settings.mode==IOSUpscalerMode::Auto && s.mode==IOSUpscalerMode::Temporal)
      ? "none" : "unsupported-or-allocation-failed");
  }

Tempest::Size IOSUpscaler::inputSize() const noexcept { return impl->input; }
IOSUpscalerMode IOSUpscaler::activeMode() const noexcept { return impl->mode; }
bool IOSUpscaler::outputIsLdr() const noexcept { return impl->mode==IOSUpscalerMode::Fsr1; }
bool IOSUpscaler::encodingFailed() const noexcept { return impl->encodeFailed; }
void IOSUpscaler::resetHistory() noexcept { impl->reset=true; impl->sample=0; }
const Tempest::Texture2d& IOSUpscaler::output() const noexcept {
  return Tempest::textureCast<const Tempest::Texture2d&>(impl->result);
  }

void IOSUpscaler::prepareCamera(IOSSceneFrameState& scene) const noexcept {
  auto& camera=scene.camera;
  camera.viewport.width=uint32_t(impl->input.w); camera.viewport.height=uint32_t(impl->input.h);
  camera.jitter={};
  scene.resetHistory |= impl->reset;
  if(impl->mode!=IOSUpscalerMode::Temporal) return;
  const uint32_t sample=impl->sample%32u+1u;
  camera.jitter={0.5f-halton(sample,2),0.5f-halton(sample,3)};
  const float x=2.f*camera.jitter.x/float(impl->input.w), y=2.f*camera.jitter.y/float(impl->input.h);
  for(size_t c=0;c<4;++c) {
    camera.viewProjection.set(0,c,camera.viewProjection.at(0,c)+x*camera.viewProjection.at(3,c));
    camera.viewProjection.set(1,c,camera.viewProjection.at(1,c)+y*camera.viewProjection.at(3,c));
    camera.projection.set(0,c,camera.projection.at(0,c)+x*camera.projection.at(3,c));
    camera.projection.set(1,c,camera.projection.at(1,c)+y*camera.projection.at(3,c));
    camera.inverseViewProjection.set(c,3,camera.inverseViewProjection.at(c,3)-
        x*camera.inverseViewProjection.at(c,0)-y*camera.inverseViewProjection.at(c,1));
    }
  }

bool IOSUpscaler::encodeNative(MTL::CommandBuffer* command, MTL::Texture* source,
                        IOSUpscalerTemporalInputs temporalInputs,
                        const IOSSceneSnapshot& snapshot, const IOSToneResolveConstants& tone) {
  auto& s=*impl;
  if(s.mode==IOSUpscalerMode::Native) { s.reset=false; return true; }
  struct Context {
    Impl& s; id<MTLTexture> source; IOSUpscalerTemporalInputs inputs;
    const IOSSceneSnapshot& snapshot; const IOSToneResolveConstants& tone;
    bool encoded=false;
    } context{s,(id<MTLTexture>)(void*)source,temporalInputs,snapshot,tone};
  const auto encode = [](void* opaque,MTL::CommandBuffer* borrowedCommand) {
      auto& c=*static_cast<Context*>(opaque); auto& s=c.s;
      id<MTLCommandBuffer> command=(id<MTLCommandBuffer>)(void*)borrowedCommand;
      @try {
#if !TARGET_OS_SIMULATOR
        if(s.mode==IOSUpscalerMode::Temporal) {
          if(c.inputs.depth==nullptr || c.inputs.motion==nullptr || c.inputs.reactive==nullptr) return;
          auto temporal=s.temporal;
          temporal.colorTexture=c.source; temporal.outputTexture=s.texture(s.result);
          temporal.depthTexture=(id<MTLTexture>)(void*)c.inputs.depth;
          temporal.motionTexture=(id<MTLTexture>)(void*)c.inputs.motion;
          temporal.reactiveMaskTexture=(id<MTLTexture>)(void*)c.inputs.reactive;
          temporal.inputContentWidth=NSUInteger(s.input.w); temporal.inputContentHeight=NSUInteger(s.input.h);
          temporal.motionVectorScaleX=float(s.input.w); temporal.motionVectorScaleY=float(s.input.h);
          temporal.jitterOffsetX=c.snapshot.currentCamera.jitter.x; temporal.jitterOffsetY=c.snapshot.currentCamera.jitter.y;
          temporal.depthReversed=NO; temporal.preExposure=1.f;
          const auto a=c.snapshot.currentCamera.position, b=c.snapshot.previousCamera.position;
          const float distance=(a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y)+(a.z-b.z)*(a.z-b.z);
          const auto& current=c.snapshot.currentCamera;
          const auto& previous=c.snapshot.previousCamera;
          float directionDot=0.f;
          for(size_t axis=0;axis<3;++axis)
            directionDot+=current.view.at(2,axis)*previous.view.at(2,axis);
          const bool projectionCut=std::abs(current.projection.at(0,0)-previous.projection.at(0,0))>
              std::abs(previous.projection.at(0,0))*0.1f ||
              std::abs(current.projection.at(1,1)-previous.projection.at(1,1))>
              std::abs(previous.projection.at(1,1))*0.1f;
          temporal.reset=s.reset || !c.snapshot.historyValid || distance>200.f*200.f ||
              directionDot<0.5f || projectionCut ||
              c.snapshot.sceneTimeMs<s.previousTime || c.snapshot.sceneTimeMs-s.previousTime>250u;
          [temporal encodeToCommandBuffer:command];
          }
        else if(s.mode==IOSUpscalerMode::Spatial) {
          s.spatial.colorTexture=c.source; s.spatial.outputTexture=s.texture(s.result);
          s.spatial.inputContentWidth=NSUInteger(s.input.w); s.spatial.inputContentHeight=NSUInteger(s.input.h);
          [s.spatial encodeToCommandBuffer:command];
          }
        else
#endif
        if(s.mode==IOSUpscalerMode::Fsr1) {
          const std::array<id<MTLTexture>,4> textures={c.source,s.texture(s.fsrInput),s.texture(s.fsrIntermediate),s.texture(s.result)};
          for(size_t i=0;i<3;++i) {
            id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
            if(compute==nil) return;
            @try {
              compute.label=i==0 ? @"FSR 1 tonemap" : i==1 ? @"FSR 1 EASU" : @"FSR 1 RCAS";
              [compute setComputePipelineState:s.fsr[i]];
              [compute setTexture:textures[i] atIndex:0]; [compute setTexture:textures[i+1] atIndex:1];
              if(i==0) [compute setBytes:&c.tone length:sizeof(c.tone) atIndex:0];
              [compute dispatchThreadgroups:MTLSizeMake((textures[i+1].width+7)/8,(textures[i+1].height+7)/8,1)
                      threadsPerThreadgroup:MTLSizeMake(8,8,1)];
              }
            @finally { [compute endEncoding]; }
            }
          }
        c.encoded=true;
        }
      @catch(NSException*) { c.encoded=false; }
      };
  encode(&context,command);
  if(context.encoded) { s.reset=false; ++s.sample; s.previousTime=snapshot.sceneTimeMs; return true; }
  s.failEncode();
  return false;
  }

bool IOSUpscaler::encodeLdrOutput(Tempest::Encoder<Tempest::CommandBuffer>& encoder) {
  bool encoded=false;
  @try {
  encoded=Tempest::MetalApi::withActiveRenderEncoder(impl->owner,encoder,impl.get(),
    [](void* opaque, MTL::RenderCommandEncoder* borrowed) {
      auto& s=*static_cast<Impl*>(opaque);
      id<MTLRenderCommandEncoder> native=(id<MTLRenderCommandEncoder>)(void*)borrowed;
      [native setRenderPipelineState:s.copyPipeline];
      [native setCullMode:MTLCullModeNone];
      [native setViewport:MTLViewport{0,0,double(s.size.w),double(s.size.h),0,1}];
      [native setScissorRect:MTLScissorRect{0,0,NSUInteger(s.size.w),NSUInteger(s.size.h)}];
      [native setFragmentTexture:s.texture(s.result) atIndex:0];
      [native drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      });
    }
  @catch(NSException*) { encoded=false; }
  if(!encoded) impl->failEncode();
  return encoded;
  }
