#include "ioslinearhdrmetal.h"

#include <Tempest/Attachment>
#include <Tempest/CommandBuffer>
#include <Tempest/Device>
#include <Tempest/Encoder>
#include <Tempest/MetalApi>
#include <Tempest/Texture2d>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cmath>
#include <string_view>

#if __has_feature(objc_arc)
#error "IOSLinearHDRMetal requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(id value = nil) noexcept : value(value) {
      }
    ~OwnedObjectiveC() {
      [value release];
      }
    OwnedObjectiveC(const OwnedObjectiveC&) = delete;
    OwnedObjectiveC& operator=(const OwnedObjectiveC&) = delete;

    id get() const noexcept {
      return value;
      }

    id relinquish() noexcept {
      const id result = value;
      value = nil;
      return result;
      }

  private:
    id value = nil;
  };

OwnedObjectiveC makeString(std::string_view value) {
  return OwnedObjectiveC(
      [[NSString alloc] initWithBytes:value.data()
                               length:value.size()
                             encoding:NSUTF8StringEncoding]);
  }

bool reflectionMatches(MTLRenderPipelineReflection* reflection) noexcept {
  if(reflection==nil || reflection.fragmentBindings==nil ||
     reflection.vertexBindings==nil)
    return false;
  for(id<MTLBinding> binding in reflection.vertexBindings) {
    if(binding.used)
      return false;
    }
  NSUInteger textures = 0u;
  NSUInteger buffers = 0u;
  for(id<MTLBinding> binding in reflection.fragmentBindings) {
    if(!binding.used)
      continue;
    if(binding.index!=NSUInteger(0u) || !binding.argument)
      return false;
    if(binding.type==MTLBindingTypeTexture) {
      ++textures;
      if(binding.access!=MTLBindingAccessReadOnly)
        return false;
      continue;
      }
    if(binding.type==MTLBindingTypeBuffer) {
      ++buffers;
      if(binding.access!=MTLBindingAccessReadOnly)
        return false;
      id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)binding;
      if(buffer.bufferDataSize!=sizeof(IOSToneResolveConstants) ||
         buffer.bufferAlignment!=alignof(IOSToneResolveConstants))
        return false;
      continue;
      }
    return false;
    }
  return textures==NSUInteger(1u) && buffers==NSUInteger(1u);
  }

bool finiteConstants(const IOSToneResolveConstants& constants) noexcept {
  return std::isfinite(constants.brightness) &&
         std::isfinite(constants.contrast) &&
         std::isfinite(constants.gamma) &&
         std::isfinite(constants.exposure) &&
         constants.contrast>=0.01f && constants.gamma>0.f &&
         constants.exposure==1.f;
  }

}

struct IOSLinearHDRMetal::Impl final {
  struct EncodeContext final {
    Impl* renderer = nullptr;
    id<MTLTexture> source = nil;
    IOSToneResolveConstants constants;
    NSUInteger width = 0u;
    NSUInteger height = 0u;
    bool encoded = false;
    };

  explicit Impl(Tempest::Device& owner)
    : owner(owner), nativeDevice(Tempest::MetalApi::borrowDevice(owner)) {
    if(!nativeDevice)
      return;
    @autoreleasepool {
      id<MTLDevice> device = (id<MTLDevice>)(void*)nativeDevice.get();
      @try {
        MTLTextureDescriptor* descriptor =
          [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRG11B10Float
                                         width:1u height:1u mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget |
                           MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if(texture!=nil) {
          probeResult = IOSLinearHDRProbeResult::success();
          [texture release];
          }
        }
      @catch(NSException* exception) {
        (void)exception;
        probeResult = IOSLinearHDRProbeResult::factoryFailed();
        }
      if(probeResult.reason()!=IOSLinearHDRProbeReason::None)
        return;

      @try {
      const OwnedObjectiveC libraryName =
          makeString(RendererIOSShader::LibraryName);
      if(libraryName.get()==nil)
        return;
      NSURL* libraryUrl =
          [[NSBundle mainBundle]
              URLForResource:(NSString*)libraryName.get()
               withExtension:@"metallib"];
      if(libraryUrl==nil)
        return;
      NSError* libraryError = nil;
      OwnedObjectiveC library(
          [device newLibraryWithURL:libraryUrl error:&libraryError]);
      if(library.get()==nil)
        return;

      const OwnedObjectiveC vertexName =
          makeString(RendererIOSShader::ToneResolveVertexFunction);
      const OwnedObjectiveC fragmentName =
          makeString(RendererIOSShader::ToneResolveFragmentFunction);
      if(vertexName.get()==nil || fragmentName.get()==nil)
        return;
      id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
      OwnedObjectiveC vertexFunction(
          [nativeLibrary newFunctionWithName:(NSString*)vertexName.get()]);
      OwnedObjectiveC fragmentFunction(
          [nativeLibrary newFunctionWithName:(NSString*)fragmentName.get()]);
      if(vertexFunction.get()==nil || fragmentFunction.get()==nil)
        return;

      OwnedObjectiveC descriptorOwner(
          [[MTLRenderPipelineDescriptor alloc] init]);
      MTLRenderPipelineDescriptor* descriptor =
          (MTLRenderPipelineDescriptor*)descriptorOwner.get();
      descriptor.vertexFunction = (id<MTLFunction>)vertexFunction.get();
      descriptor.fragmentFunction = (id<MTLFunction>)fragmentFunction.get();
      descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      descriptor.colorAttachments[0].blendingEnabled = NO;
      descriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
      descriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
      descriptor.rasterSampleCount = 1u;
      descriptor.alphaToCoverageEnabled = NO;
      descriptor.alphaToOneEnabled = NO;

      NSError* pipelineError = nil;
      MTLRenderPipelineReflection* reflection = nil;
      OwnedObjectiveC pipelineOwner(
          [device newRenderPipelineStateWithDescriptor:descriptor
                                               options:(
              MTLPipelineOptionBindingInfo |
              MTLPipelineOptionBufferTypeInfo)
                                            reflection:&reflection
                                                 error:&pipelineError]);
      if(pipelineOwner.get()==nil || !reflectionMatches(reflection))
        return;
      pipelineState = pipelineOwner.relinquish();
        }
      @catch(NSException* exception) {
        (void)exception;
        return;
        }
      }
    }

  ~Impl() {
    [pipelineState release];
    }

  bool exactTarget(const Tempest::Attachment& target,
                   uint32_t width, uint32_t height) const noexcept {
    try {
      if(target.isEmpty() || target.w()!=int(width) || target.h()!=int(height))
        return false;
      const auto& texture =
          Tempest::textureCast<const Tempest::Texture2d&>(target);
      const auto native = Tempest::MetalApi::borrowTexture(owner,texture);
      if(!native)
        return false;
      id<MTLTexture> value = (id<MTLTexture>)(void*)native.get();
      constexpr MTLTextureUsage usage =
          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      return value.pixelFormat==MTLPixelFormatRG11B10Float &&
             value.storageMode==MTLStorageModePrivate &&
             value.textureType==MTLTextureType2D &&
             value.width==NSUInteger(width) &&
             value.height==NSUInteger(height) &&
             value.mipmapLevelCount==NSUInteger(1u) &&
             value.arrayLength==NSUInteger(1u) &&
             value.sampleCount==NSUInteger(1u) &&
             value.usage==usage;
      }
    catch(...) {
      return false;
      }
    }

  static void encode(void* opaque,
                     MTL::RenderCommandEncoder* nativeEncoder) {
    auto& context = *static_cast<EncodeContext*>(opaque);
    id<MTLRenderCommandEncoder> encoder =
        (id<MTLRenderCommandEncoder>)(void*)nativeEncoder;
    [encoder setRenderPipelineState:
        (id<MTLRenderPipelineState>)context.renderer->pipelineState];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setViewport:MTLViewport{0.0,0.0,
                                    double(context.width),
                                    double(context.height),0.0,1.0}];
    [encoder setScissorRect:MTLScissorRect{0u,0u,
                                          context.width,
                                          context.height}];
    [encoder setFragmentTexture:context.source atIndex:0u];
    [encoder setFragmentBytes:&context.constants
                       length:sizeof(context.constants)
                      atIndex:0u];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0u vertexCount:3u];
    context.encoded = true;
    }

  Tempest::Device& owner;
  Tempest::BorrowedMetalDevice nativeDevice;
  IOSLinearHDRProbeResult probeResult =
      IOSLinearHDRProbeResult::factoryFailed();
  id pipelineState = nil;
  };

IOSLinearHDRMetal::IOSLinearHDRMetal(Tempest::Device& device)
  : impl(std::make_unique<Impl>(device)) {
  }

IOSLinearHDRMetal::~IOSLinearHDRMetal() = default;

IOSLinearHDRProbeResult IOSLinearHDRMetal::probe() const noexcept {
  return impl!=nullptr ? impl->probeResult
                       : IOSLinearHDRProbeResult::factoryFailed();
  }

bool IOSLinearHDRMetal::resolvePipelineReady() const noexcept {
  return impl!=nullptr && impl->pipelineState!=nil;
  }

bool IOSLinearHDRMetal::exactTarget(const Tempest::Attachment& target,
                                    uint32_t width,
                                    uint32_t height) const noexcept {
  return impl!=nullptr && impl->exactTarget(target,width,height);
  }

IOSLinearHDRMetalEncodeResult IOSLinearHDRMetal::encodeToneResolve(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const Tempest::Attachment& source,
    const IOSToneResolveConstants& constants) noexcept {
  if(impl==nullptr || impl->pipelineState==nil)
    return IOSLinearHDRMetalEncodeResult::PipelineUnavailable;
  if(!finiteConstants(constants) || source.isEmpty())
    return IOSLinearHDRMetalEncodeResult::InvalidSource;
  try {
    const auto& texture =
        Tempest::textureCast<const Tempest::Texture2d&>(source);
    const auto native = Tempest::MetalApi::borrowTexture(impl->owner,texture);
    if(!native || !impl->exactTarget(
         source,static_cast<uint32_t>(source.w()),
         static_cast<uint32_t>(source.h())))
      return IOSLinearHDRMetalEncodeResult::InvalidSource;
    Impl::EncodeContext context;
    context.renderer = impl.get();
    context.source = (id<MTLTexture>)(void*)native.get();
    context.constants = constants;
    context.width = NSUInteger(source.w());
    context.height = NSUInteger(source.h());
    if(!Tempest::MetalApi::withActiveRenderEncoder(
           impl->owner,encoder,&context,&Impl::encode))
      return IOSLinearHDRMetalEncodeResult::NoActiveRenderEncoder;
    return context.encoded ? IOSLinearHDRMetalEncodeResult::Success
                           : IOSLinearHDRMetalEncodeResult::NativeEncodingFailed;
    }
  catch(...) {
    return IOSLinearHDRMetalEncodeResult::NativeEncodingFailed;
    }
  }

const char* iosLinearHDRMetalEncodeResultName(
    IOSLinearHDRMetalEncodeResult result) noexcept {
  switch(result) {
    case IOSLinearHDRMetalEncodeResult::Success:
      return "success";
    case IOSLinearHDRMetalEncodeResult::PipelineUnavailable:
      return "pipeline-unavailable";
    case IOSLinearHDRMetalEncodeResult::InvalidSource:
      return "invalid-source";
    case IOSLinearHDRMetalEncodeResult::NoActiveRenderEncoder:
      return "no-active-render-encoder";
    case IOSLinearHDRMetalEncodeResult::NativeEncodingFailed:
      return "native-encoding-failed";
    }
  return "unknown";
  }
