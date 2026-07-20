#include "iosgpubink.h"

#include "ioslandscapeshaderabi.h"

#include <Tempest/Device>
#include <Tempest/Log>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdexcept>
#include <string>

#if __has_feature(objc_arc)
#error "IOSGPUBink requires the project's non-ARC Objective-C++ mode"
#endif

namespace {

class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(id value = nil) noexcept
      : value(value) {
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

std::string metalFailure(const char* operation, NSError* error) {
  std::string result(operation);
  result += ": ";
  if(error==nil || error.localizedDescription==nil) {
    result += "unknown Metal error";
    return result;
    }
  const char* description = error.localizedDescription.UTF8String;
  result += description!=nullptr ? description : "unknown Metal error";
  return result;
  }

}

struct IOSGPUBink::Impl final {
  struct EncodeContext final {
    Impl*                         renderer = nullptr;
    id<MTLBuffer>                 planes = nil;
    IOSBinkShaderConstants        constants;
    IOSGPUBink::PlaneLayout       layout;
    bool                          encoded = false;
    };

  explicit Impl(Tempest::Device& owner)
    : owner(owner),nativeDevice(Tempest::MetalApi::borrowDevice(owner)) {
    if(!nativeDevice)
      throw std::invalid_argument(
          "RendererIOS IOSGPUBink requires the owning Tempest Metal device");

    @autoreleasepool {
      id<MTLDevice> device = (id<MTLDevice>)(void*)nativeDevice.get();
      OwnedObjectiveC libraryName(
          [[NSString alloc]
              initWithBytes:RendererIOSShader::LibraryName.data()
                     length:RendererIOSShader::LibraryName.size()
                   encoding:NSUTF8StringEncoding]);
      if(libraryName.get()==nil)
        throw std::runtime_error(
            "RendererIOS IOSGPUBink could not create its metallib resource name");

      NSBundle* bundle = [NSBundle mainBundle];
      NSURL* libraryUrl =
          [bundle URLForResource:(NSString*)libraryName.get()
                   withExtension:@"metallib"];
      if(libraryUrl==nil)
        throw std::runtime_error(
            "RendererIOS IOSGPUBink could not find RendererIOS.metallib");

      NSError* libraryError = nil;
      OwnedObjectiveC library(
          [device newLibraryWithURL:libraryUrl error:&libraryError]);
      if(library.get()==nil)
        throw std::runtime_error(
            metalFailure("RendererIOS IOSGPUBink metallib loading failed",
                         libraryError));

      OwnedObjectiveC vertexName(
          [[NSString alloc]
              initWithBytes:RendererIOSBinkShader::VertexFunction.data()
                     length:RendererIOSBinkShader::VertexFunction.size()
                   encoding:NSUTF8StringEncoding]);
      OwnedObjectiveC fragmentName(
          [[NSString alloc]
              initWithBytes:RendererIOSBinkShader::FragmentFunction.data()
                     length:RendererIOSBinkShader::FragmentFunction.size()
                   encoding:NSUTF8StringEncoding]);
      id<MTLLibrary> nativeLibrary = (id<MTLLibrary>)library.get();
      OwnedObjectiveC vertexFunction(
          [nativeLibrary newFunctionWithName:(NSString*)vertexName.get()]);
      OwnedObjectiveC fragmentFunction(
          [nativeLibrary newFunctionWithName:(NSString*)fragmentName.get()]);
      if(vertexFunction.get()==nil || fragmentFunction.get()==nil)
        throw std::runtime_error(
            "RendererIOS IOSGPUBink could not resolve its Metal shader functions");

      OwnedObjectiveC pipelineDescriptor(
          [[MTLRenderPipelineDescriptor alloc] init]);
      MTLRenderPipelineDescriptor* descriptor =
          (MTLRenderPipelineDescriptor*)pipelineDescriptor.get();
      descriptor.vertexFunction =
          (id<MTLFunction>)vertexFunction.get();
      descriptor.fragmentFunction =
          (id<MTLFunction>)fragmentFunction.get();
      descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      descriptor.rasterSampleCount = 1u;

      NSError* pipelineError = nil;
      OwnedObjectiveC pipelineOwner(
          [device newRenderPipelineStateWithDescriptor:descriptor
                                                 error:&pipelineError]);
      if(pipelineOwner.get()==nil)
        throw std::runtime_error(
            metalFailure("RendererIOS IOSGPUBink pipeline creation failed",
                         pipelineError));
      pipelineState = pipelineOwner.relinquish();
      Tempest::Log::i(
          "RendererIOS native Bink pipeline: source=offline-metallib resource=",
          RendererIOSShader::LibraryName,".metallib abi=",
          RendererIOSShader::AbiVersion,
          " color=rgba8 sample-count=1 pipeline-created=1");
      }
    }

  ~Impl() {
    [pipelineState release];
    }

  static void encodeFrame(void* opaque,
                          MTL::RenderCommandEncoder* nativeEncoder) {
    auto& context = *static_cast<EncodeContext*>(opaque);
    if(context.renderer==nullptr || context.planes==nil ||
       nativeEncoder==nullptr)
      return;

    id<MTLRenderCommandEncoder> encoder =
        (id<MTLRenderCommandEncoder>)(void*)nativeEncoder;
    [encoder setRenderPipelineState:
        (id<MTLRenderPipelineState>)context.renderer->pipelineState];
    [encoder setFragmentBuffer:context.planes
                        offset:0u
                       atIndex:RendererIOSBinkShader::PlaneYBufferIndex];
    [encoder setFragmentBuffer:context.planes
                        offset:context.layout.offsetU
                       atIndex:RendererIOSBinkShader::PlaneUBufferIndex];
    [encoder setFragmentBuffer:context.planes
                        offset:context.layout.offsetV
                       atIndex:RendererIOSBinkShader::PlaneVBufferIndex];
    [encoder setFragmentBytes:&context.constants
                       length:sizeof(context.constants)
                      atIndex:RendererIOSBinkShader::ConstantsBufferIndex];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0u
                vertexCount:3u];
    [encoder setFragmentBuffer:nil offset:0u
                       atIndex:RendererIOSBinkShader::PlaneYBufferIndex];
    [encoder setFragmentBuffer:nil offset:0u
                       atIndex:RendererIOSBinkShader::PlaneUBufferIndex];
    [encoder setFragmentBuffer:nil offset:0u
                       atIndex:RendererIOSBinkShader::PlaneVBufferIndex];
    context.encoded = true;
    }

  Tempest::Device&             owner;
  Tempest::BorrowedMetalDevice nativeDevice;
  id                           pipelineState = nil;
  uint64_t                     encodedFrames = 0;
  };

IOSGPUBink::IOSGPUBink(Tempest::Device& device)
  : impl(std::make_unique<Impl>(device)) {
  }

IOSGPUBink::~IOSGPUBink() = default;

void IOSGPUBink::encode(
    Tempest::Encoder<Tempest::CommandBuffer>& encoder,
    const Tempest::StorageBuffer& planes,
    const PlaneLayout& layout) {
  if(impl==nullptr || impl->pipelineState==nil)
    throw std::runtime_error("RendererIOS IOSGPUBink pipeline is unavailable");
  const auto nativePlanes = Tempest::MetalApi::borrowBuffer(impl->owner,planes);
  if(!nativePlanes)
    throw std::runtime_error(
        "RendererIOS IOSGPUBink received a non-Metal plane buffer");

  Impl::EncodeContext context;
  context.renderer         = impl.get();
  context.planes           = (id<MTLBuffer>)(void*)nativePlanes.get();
  context.constants.strideY = layout.strideY;
  context.constants.strideU = layout.strideU;
  context.constants.strideV = layout.strideV;
  context.layout            = layout;
  if(!Tempest::MetalApi::withActiveRenderEncoder(
         impl->owner,encoder,&context,&Impl::encodeFrame))
    throw std::runtime_error(
        "RendererIOS IOSGPUBink has no active Tempest render encoder");
  if(!context.encoded)
    throw std::runtime_error(
        "RendererIOS IOSGPUBink failed to encode its native draw");
  ++impl->encodedFrames;
  }

uint64_t IOSGPUBink::encodedFrames() const noexcept {
  return impl!=nullptr ? impl->encodedFrames : 0u;
  }
