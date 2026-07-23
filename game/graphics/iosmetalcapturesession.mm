#include "iosmetalcapturesession.h"

#if defined(OPENGOTHIC_RENDERER_IOS_CLEAR_ONLY_PASS_SELF_TEST) || \
    defined(OPENGOTHIC_RENDERER_IOS_SHADING_PROTOTYPE_TILE_SELF_TEST)

#include <Tempest/Device>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cerrno>
#include <cstring>
#include <new>
#include <sys/stat.h>

#if __has_feature(objc_arc)
#error "IOSMetalCaptureSession requires non-ARC Objective-C++ mode"
#endif

namespace {

template<class T>
class OwnedObjectiveC final {
  public:
    explicit OwnedObjectiveC(T value = nil) noexcept
      : value(value) {
      }

    ~OwnedObjectiveC() noexcept {
      @try {
        [value release];
        }
      @catch(NSException*) {
        }
      }

    OwnedObjectiveC(const OwnedObjectiveC&) = delete;
    OwnedObjectiveC& operator=(const OwnedObjectiveC&) = delete;

    T get() const noexcept {
      return value;
      }

  private:
    T value = nil;
  };

bool validCaptureArtifactName(const char* artifactName) noexcept {
  if(artifactName==nullptr || artifactName[0]=='\0')
    return false;
  constexpr char suffix[] = ".gputrace";
  const std::size_t length = std::strlen(artifactName);
  if(length<=sizeof(suffix)-1u ||
     std::strcmp(artifactName+length-(sizeof(suffix)-1u),suffix)!=0)
    return false;
  for(std::size_t index=0u;index<length;++index) {
    const char value = artifactName[index];
    if(value=='/' || value=='\\' || value=='\n' || value=='\r')
      return false;
    }
  return std::strcmp(artifactName,".")!=0 &&
         std::strcmp(artifactName,"..")!=0;
  }

}

struct IOSMetalCaptureSession::Impl final {
  MTLCaptureManager* manager = nil;
  NSURL* outputURL = nil;
  bool captureActive = false;

  ~Impl() {
    if(captureActive && manager!=nil) {
      @try {
        [manager stopCapture];
        }
      @catch(NSException*) {
        }
      }
    @try {
      [outputURL release];
      }
    @catch(NSException*) {
      }
    @try {
      [manager release];
      }
    @catch(NSException*) {
      }
    }
  };

IOSMetalCaptureSession::~IOSMetalCaptureSession() {
  reset();
  }

bool IOSMetalCaptureSession::start(
    Tempest::Device& device,
    const char* artifactName,
    const char*& reason) noexcept {
  reason = "capture-start-failed";
  if(impl!=nullptr || !validCaptureArtifactName(artifactName)) {
    reason = impl!=nullptr ? "capture-already-initialized"
                           : "capture-output-name-invalid";
    return false;
    }
  impl = new(std::nothrow) Impl();
  if(impl==nullptr) {
    reason = "capture-state-allocation-failed";
    return false;
    }

  @autoreleasepool {
    @try {
      const auto borrowed = Tempest::MetalApi::borrowDevice(device);
      id<MTLDevice> nativeDevice =
          reinterpret_cast<id<MTLDevice>>((void*)borrowed.get());
      if(nativeDevice==nil) {
        reason = "capture-device-unavailable";
        return false;
        }

      OwnedObjectiveC<NSFileManager*> files(
          [[NSFileManager alloc] init]);
      if(files.get()==nil) {
        reason = "capture-file-manager-unavailable";
        return false;
        }
      NSArray<NSURL*>* documents =
          [files.get() URLsForDirectory:NSDocumentDirectory
                              inDomains:NSUserDomainMask];
      NSURL* documentsURL = [documents lastObject];
      NSString* captureName =
          [NSString stringWithUTF8String:artifactName];
      NSURL* outputURL = [documentsURL
          URLByAppendingPathComponent:captureName
                           isDirectory:NO];
      const bool exactPath = captureName!=nil && documentsURL!=nil &&
          outputURL!=nil &&
          [[outputURL lastPathComponent]
            isEqualToString:captureName] &&
          [[[outputURL URLByDeletingLastPathComponent] standardizedURL]
            isEqual:[documentsURL standardizedURL]];
      if(!exactPath) {
        reason = "capture-output-path-invalid";
        return false;
        }

      const char* outputPath = [outputURL fileSystemRepresentation];
      if(outputPath==nullptr) {
        reason = "capture-output-path-unavailable";
        return false;
        }
      struct stat existing = {};
      if(::lstat(outputPath,&existing)==0) {
        NSError* removeError = nil;
        if(![files.get() removeItemAtURL:outputURL error:&removeError]) {
          (void)removeError;
          reason = "capture-stale-artifact-removal-failed";
          return false;
          }
        }
      else if(errno!=ENOENT) {
        reason = "capture-stale-artifact-inspection-failed";
        return false;
        }
      if(::lstat(outputPath,&existing)==0 || errno!=ENOENT) {
        reason = "capture-output-not-empty";
        return false;
        }

      MTLCaptureManager* manager = [MTLCaptureManager sharedCaptureManager];
      if(manager==nil ||
         ![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
        reason = "capture-gputrace-destination-unsupported";
        return false;
        }
      OwnedObjectiveC<MTLCaptureDescriptor*> descriptor(
          [[MTLCaptureDescriptor alloc] init]);
      if(descriptor.get()==nil) {
        reason = "capture-descriptor-allocation-failed";
        return false;
        }
      descriptor.get().captureObject = nativeDevice;
      descriptor.get().destination = MTLCaptureDestinationGPUTraceDocument;
      descriptor.get().outputURL = outputURL;
      impl->manager = [manager retain];
      impl->outputURL = [outputURL retain];
      // An Objective-C exception is ambiguous: teardown retries stopCapture,
      // and the owning context must retain this session until confirmed idle.
      impl->captureActive = true;
      NSError* captureError = nil;
      const BOOL started = [manager startCaptureWithDescriptor:descriptor.get()
                                                         error:&captureError];
      (void)captureError;
      if(!started) {
        impl->captureActive = false;
        reason = "capture-manager-start-rejected";
        return false;
        }

      reason = nullptr;
      return true;
      }
    @catch(NSException*) {
      reason = "capture-start-objective-c-exception";
      return false;
      }
    }
  }

bool IOSMetalCaptureSession::stopAndInspect(
    IOSMetalCaptureArtifact& artifact,
    const char*& reason) noexcept {
  artifact = {};
  reason = "capture-stop-failed";
  if(impl==nullptr || !impl->captureActive || impl->manager==nil ||
     impl->outputURL==nil) {
    reason = "capture-not-active";
    return false;
    }
  @autoreleasepool {
    @try {
      [impl->manager stopCapture];
      impl->captureActive = false;
      const char* rawPath = [impl->outputURL fileSystemRepresentation];
      if(rawPath==nullptr) {
        reason = "capture-output-path-unavailable-after-stop";
        return false;
        }
      if(!iosMetalNormalizeAndInspectCaptureArtifact(
           rawPath,artifact,reason)) {
        if(reason==nullptr)
          reason = "capture-artifact-invalid";
        return false;
        }
      reason = nullptr;
      return true;
      }
    @catch(NSException*) {
      reason = "capture-stop-objective-c-exception";
      return false;
      }
    }
  }

void IOSMetalCaptureSession::cancel() noexcept {
  if(impl==nullptr || !impl->captureActive || impl->manager==nil)
    return;
  @try {
    [impl->manager stopCapture];
    impl->captureActive = false;
    }
  @catch(NSException*) {
    }
  }

void IOSMetalCaptureSession::reset() noexcept {
  cancel();
  delete impl;
  impl = nullptr;
  }

bool IOSMetalCaptureSession::active() const noexcept {
  return impl!=nullptr && impl->captureActive;
  }

const char* iosMetalCaptureArtifactKindName(
    IOSMetalCaptureArtifactKind kind) noexcept {
  switch(kind) {
    case IOSMetalCaptureArtifactKind::File:      return "file";
    case IOSMetalCaptureArtifactKind::Directory: return "directory";
    }
  return "invalid";
  }

#endif
