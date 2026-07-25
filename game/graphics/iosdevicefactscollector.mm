#include "iosdevicefactscollector.h"

#include <Tempest/Device>
#include <Tempest/Log>
#include <Tempest/MetalApi>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METALFX 1
#else
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METALFX 0
#endif
#import <TargetConditionals.h>

#include <cstdio>
#include <limits>

namespace {

constexpr uint8_t FormatCount =
    static_cast<uint8_t>(IOSDeviceFormatId::Count);

#if TARGET_OS_IOS

#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
     __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000) || \
    (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
     __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000)
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL4 1
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE10 1
#else
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL4 0
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE10 0
#endif

#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
     __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000) || \
    (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
     __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000)
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE9 1
#else
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE9 0
#endif

#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
     __IPHONE_OS_VERSION_MAX_ALLOWED >= 160000) || \
    (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
     __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000)
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE8 1
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL3 1
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_MESH 1
#else
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE8 0
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL3 0
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_MESH 0
#endif

#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && \
     __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000) || \
    (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
     __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000)
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_RAYTRACING 1
#else
#define OPENGOTHIC_IOS_DEVICE_FACTS_HAS_RAYTRACING 0
#endif

constexpr uint16_t appleFamilyBit(uint8_t family) noexcept {
  return static_cast<uint16_t>(uint16_t(1u) << family);
  }

constexpr uint8_t metalFamilyBit(uint8_t family) noexcept {
  return static_cast<uint8_t>(uint8_t(1u) << family);
  }

constexpr uint32_t limitBit(IOSDeviceLimitId limit) noexcept {
  return uint32_t(1u) << static_cast<uint8_t>(limit);
  }

void setAvailability(
    IOSDeviceNativeSnapshot& result,
    IOSDeviceProbeId probe,
    bool available) noexcept {
  result.probes[static_cast<uint8_t>(probe)].availability =
      available ? IOSDeviceNativeTruth::Yes
                : IOSDeviceNativeTruth::No;
  }

void setSupport(
    IOSDeviceNativeSnapshot& result,
    IOSDeviceProbeId probe,
    bool supported) noexcept {
  result.probes[static_cast<uint8_t>(probe)].deviceSupport =
      supported ? IOSDeviceNativeTruth::Yes
                : IOSDeviceNativeTruth::No;
  }

void queryAppleFamily(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device,
    uint8_t family,
    MTLGPUFamily nativeFamily) noexcept {
  @try {
    const bool supported = [device supportsFamily:nativeFamily]==YES;
    result.knownAppleFamilyMask |= appleFamilyBit(family);
    if(supported)
      result.supportedAppleFamilyMask |= appleFamilyBit(family);
  }
  @catch(NSException*) {
  }
  }

void queryMetalFamily(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device,
    uint8_t family,
    MTLGPUFamily nativeFamily) noexcept {
  @try {
    const bool supported = [device supportsFamily:nativeFamily]==YES;
    result.knownMetalFamilyMask |= metalFamilyBit(family);
    if(supported)
      result.supportedMetalFamilyMask |= metalFamilyBit(family);
  }
  @catch(NSException*) {
  }
  }

void collectRuntimeVersion(IOSDeviceNativeSnapshot& result) noexcept {
  @try {
    const NSOperatingSystemVersion version =
        [[NSProcessInfo processInfo] operatingSystemVersion];
    result.runtimeVersion.major = version.majorVersion;
    result.runtimeVersion.minor = version.minorVersion;
    result.runtimeVersion.patch = version.patchVersion;
    result.runtimeVersion.known = IOSDeviceNativeTruth::Yes;
  }
  @catch(NSException*) {
  }
  }

void collectSdkVersion(IOSDeviceNativeSnapshot& result) noexcept {
  constexpr int64_t Version = __IPHONE_OS_VERSION_MAX_ALLOWED;
  result.sdkVersion.major = Version / 10000;
  result.sdkVersion.minor = (Version / 100) % 100;
  result.sdkVersion.patch = Version % 100;
  result.sdkVersion.known = IOSDeviceNativeTruth::Yes;
  }

void collectAppleFamilies(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE10
  if(@available(iOS 26.0, macOS 26.0, *))
    queryAppleFamily(result,device,10u,MTLGPUFamilyApple10);
#endif
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE9
  if(@available(iOS 17.0, macOS 14.0, *))
    queryAppleFamily(result,device,9u,MTLGPUFamilyApple9);
#endif
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_APPLE8
  if(@available(iOS 16.0, macOS 13.0, *))
    queryAppleFamily(result,device,8u,MTLGPUFamilyApple8);
#endif
  queryAppleFamily(result,device,7u,MTLGPUFamilyApple7);
  queryAppleFamily(result,device,6u,MTLGPUFamilyApple6);
  queryAppleFamily(result,device,5u,MTLGPUFamilyApple5);
  queryAppleFamily(result,device,4u,MTLGPUFamilyApple4);
  queryAppleFamily(result,device,3u,MTLGPUFamilyApple3);
  queryAppleFamily(result,device,2u,MTLGPUFamilyApple2);
  queryAppleFamily(result,device,1u,MTLGPUFamilyApple1);
  }

void collectMetalFamilies(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL4
  if(@available(iOS 26.0, macOS 26.0, *))
    queryMetalFamily(result,device,4u,MTLGPUFamilyMetal4);
#endif
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL3
  if(@available(iOS 16.0, macOS 13.0, *))
    queryMetalFamily(result,device,3u,MTLGPUFamilyMetal3);
#endif
  }

void collectSpatialProbe(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METALFX
  @try {
    bool available = false;
    if(@available(iOS 16.0, *)) {
      Class descriptorClass = [MTLFXSpatialScalerDescriptor class];
      available =
          descriptorClass!=Nil &&
          [descriptorClass respondsToSelector:
              @selector(supportsDevice:)]==YES;
    }
    setAvailability(
        result,IOSDeviceProbeId::MetalFxSpatial,available);
  }
  @catch(NSException*) {
  }
  if(result.probes[static_cast<uint8_t>(
       IOSDeviceProbeId::MetalFxSpatial)].availability==
     IOSDeviceNativeTruth::Yes) {
    @try {
      setSupport(
          result,IOSDeviceProbeId::MetalFxSpatial,
          [MTLFXSpatialScalerDescriptor supportsDevice:device]==YES);
    }
    @catch(NSException*) {
    }
  }
#endif
  }

void collectTemporalProbe(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METALFX
  @try {
    bool available = false;
    if(@available(iOS 16.0, *)) {
      Class descriptorClass = [MTLFXTemporalScalerDescriptor class];
      available =
          descriptorClass!=Nil &&
          [descriptorClass respondsToSelector:
              @selector(supportsDevice:)]==YES;
    }
    setAvailability(
        result,IOSDeviceProbeId::MetalFxTemporal,available);
  }
  @catch(NSException*) {
  }
  if(result.probes[static_cast<uint8_t>(
       IOSDeviceProbeId::MetalFxTemporal)].availability==
     IOSDeviceNativeTruth::Yes) {
    @try {
      setSupport(
          result,IOSDeviceProbeId::MetalFxTemporal,
          [MTLFXTemporalScalerDescriptor supportsDevice:device]==YES);
    }
    @catch(NSException*) {
    }
  }
#endif
  }

void collectMeshProbe(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_MESH
  @try {
    bool available = false;
    if(@available(iOS 16.0, macOS 13.0, *)) {
      available = [device respondsToSelector:@selector(
          newRenderPipelineStateWithMeshDescriptor:
          options:reflection:error:)]==YES;
    }
    setAvailability(result,IOSDeviceProbeId::MeshShading,available);
  }
  @catch(NSException*) {
  }
#endif
  }

void collectRayTracingProbe(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_RAYTRACING
  @try {
    bool available = false;
    if(@available(iOS 14.0, macOS 11.0, *))
      available = [device respondsToSelector:
          @selector(supportsRaytracing)]==YES;
    setAvailability(result,IOSDeviceProbeId::RayTracing,available);
  }
  @catch(NSException*) {
  }
  if(result.probes[static_cast<uint8_t>(
       IOSDeviceProbeId::RayTracing)].availability==
     IOSDeviceNativeTruth::Yes) {
    @try {
      setSupport(
          result,IOSDeviceProbeId::RayTracing,
          [device supportsRaytracing]==YES);
    }
    @catch(NSException*) {
    }
  }
#endif
  }

void collectMetal4Probe(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
#if OPENGOTHIC_IOS_DEVICE_FACTS_HAS_METAL4
  @try {
    bool available = false;
    if(@available(iOS 26.0, macOS 26.0, *))
      available = [device respondsToSelector:
          @selector(newMTL4CommandQueue)]==YES;
    setAvailability(
        result,IOSDeviceProbeId::Metal4Transport,available);
  }
  @catch(NSException*) {
  }
  if(result.probes[static_cast<uint8_t>(
       IOSDeviceProbeId::Metal4Transport)].availability==
     IOSDeviceNativeTruth::Yes) {
    if(@available(iOS 26.0, macOS 26.0, *)) {
      @try {
        setSupport(
            result,IOSDeviceProbeId::Metal4Transport,
            [device supportsFamily:MTLGPUFamilyMetal4]==YES);
      }
      @catch(NSException*) {
      }
    }
  }
#else
  (void)result;
  (void)device;
#endif
  }

void collectLimit(
    IOSDeviceNativeSnapshot& result,
    IOSDeviceLimitId limit,
    uint64_t value) noexcept {
  const uint8_t index = static_cast<uint8_t>(limit);
  result.knownLimitMask |= limitBit(limit);
  result.limits[index] = value;
  }

void collectLimits(
    IOSDeviceNativeSnapshot& result,
    id<MTLDevice> device) noexcept {
  @try {
    collectLimit(
        result,IOSDeviceLimitId::ComputeMaxGroupSizeX,
        [device maxThreadsPerThreadgroup].width);
  }
  @catch(NSException*) {
  }
  @try {
    collectLimit(
        result,IOSDeviceLimitId::ComputeMaxGroupSizeY,
        [device maxThreadsPerThreadgroup].height);
  }
  @catch(NSException*) {
  }
  @try {
    collectLimit(
        result,IOSDeviceLimitId::ComputeMaxGroupSizeZ,
        [device maxThreadsPerThreadgroup].depth);
  }
  @catch(NSException*) {
  }
  @try {
    collectLimit(
        result,IOSDeviceLimitId::ComputeMaxSharedMemoryBytes,
        [device maxThreadgroupMemoryLength]);
  }
  @catch(NSException*) {
  }
  }

#endif

char probeStage(
    const IOSDeviceFactsData* facts,
    IOSDeviceProbeId probe,
    IOSDeviceProbeStage stage) noexcept {
  if(facts==nullptr)
    return 'U';
  const ProbeFacts& value =
      facts->probes[static_cast<uint8_t>(probe)];
  if((value.knownStages & stage)==0u)
    return 'U';
  return (value.passedStages & stage)!=0u ? '1' : '0';
  }

bool hasKnownDeviceFacts(const IOSDeviceFactsData* facts) noexcept {
  if(facts==nullptr)
    return false;
  if(facts->highestKnownAppleFamily!=0u ||
     facts->highestKnownMetalFamily!=0u ||
     facts->knownLimitMask!=0u)
    return true;
  for(uint8_t i=0u; i<FormatCount; ++i) {
    if(facts->formats[i].knownUsages!=0u)
      return true;
  }
  for(uint8_t i=0u;
      i<static_cast<uint8_t>(IOSDeviceProbeId::Count); ++i) {
    if(facts->probes[i].knownStages!=0u)
      return true;
  }
  return false;
  }

void logFacts(const IOSDeviceFactsCreateResult& result) {
  const IOSDeviceFactsData* facts =
      result.value.has_value() ? &result.value->facts() : nullptr;
  IOSVersionTriplet runtime{};
  IOSVersionTriplet sdk{};
  uint8_t apple = 0u;
  uint8_t metal = 0u;
  uint8_t knownFormats = 0u;
  uint8_t supportedFormats = 0u;
  uint32_t knownLimitMask = 0u;
  uint32_t limit4 = 0u;
  uint32_t limit5 = 0u;
  uint32_t limit6 = 0u;
  uint32_t limit8 = 0u;
  if(facts!=nullptr) {
    runtime = facts->runtimeVersion;
    sdk = facts->sdkVersion;
    apple = facts->highestKnownAppleFamily;
    metal = facts->highestKnownMetalFamily;
    for(uint8_t i=0u; i<FormatCount; ++i) {
      knownFormats |= facts->formats[i].knownUsages;
      supportedFormats |= facts->formats[i].supportedUsages;
    }
    knownLimitMask = facts->knownLimitMask;
    limit4 = facts->limits[static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeX)];
    limit5 = facts->limits[static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeY)];
    limit6 = facts->limits[static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxGroupSizeZ)];
    limit8 = facts->limits[static_cast<uint8_t>(
        IOSDeviceLimitId::ComputeMaxSharedMemoryBytes)];
  }

  static constexpr char MarkerPrefix[] =
      "RendererIOS device facts: ";
  static constexpr char MaximumMarkerTail[] =
      "d=1 v=1 fail=255/255/255/4294967295 "
      "rt=65535.65535.65535 sdk=65535.65535.65535 fam=255/255 "
      "probes=U/U,U/U,U/U,U/U,U/U fmt=255/255 mask=0xffffffff "
      "limits=4294967295/4294967295/4294967295/4294967295";
  static_assert(
      sizeof(MarkerPrefix)+sizeof(MaximumMarkerTail)-1u<250u);
  char marker[250] = {};
  const int length = std::snprintf(
      marker,sizeof(marker),
      "%sd=%u v=%u fail=%u/%u/%u/%u "
      "rt=%u.%u.%u sdk=%u.%u.%u fam=%u/%u "
      "probes=%c/%c,%c/%c,%c/%c,%c/%c,%c/%c "
      "fmt=%u/%u mask=0x%x limits=%u/%u/%u/%u",
      MarkerPrefix,
      unsigned(hasKnownDeviceFacts(facts)),
      unsigned(result.value.has_value()),
      unsigned(result.failure.error),
      unsigned(result.failure.section),
      unsigned(result.failure.index),
      unsigned(result.failure.raw),
      unsigned(runtime.major),unsigned(runtime.minor),
      unsigned(runtime.patch),
      unsigned(sdk.major),unsigned(sdk.minor),unsigned(sdk.patch),
      unsigned(apple),unsigned(metal),
      probeStage(facts,IOSDeviceProbeId::MetalFxSpatial,Availability),
      probeStage(facts,IOSDeviceProbeId::MetalFxSpatial,DeviceSupport),
      probeStage(facts,IOSDeviceProbeId::MetalFxTemporal,Availability),
      probeStage(facts,IOSDeviceProbeId::MetalFxTemporal,DeviceSupport),
      probeStage(facts,IOSDeviceProbeId::MeshShading,Availability),
      probeStage(facts,IOSDeviceProbeId::MeshShading,DeviceSupport),
      probeStage(facts,IOSDeviceProbeId::RayTracing,Availability),
      probeStage(facts,IOSDeviceProbeId::RayTracing,DeviceSupport),
      probeStage(facts,IOSDeviceProbeId::Metal4Transport,Availability),
      probeStage(facts,IOSDeviceProbeId::Metal4Transport,DeviceSupport),
      unsigned(knownFormats),unsigned(supportedFormats),
      unsigned(knownLimitMask),
      unsigned(limit4),unsigned(limit5),unsigned(limit6),unsigned(limit8));
  if(length<0 || static_cast<size_t>(length)>=sizeof(marker))
    return;
  Tempest::Log::i(marker);
  }

}

IOSDeviceFactsCreateResult iosCollectDeviceFacts(
    const Tempest::Device& owner) noexcept {
  IOSDeviceNativeSnapshot snapshot;
#if TARGET_OS_IOS
  collectRuntimeVersion(snapshot);
  collectSdkVersion(snapshot);

  {
    const Tempest::BorrowedMetalDevice borrowedDevice =
        Tempest::MetalApi::borrowDevice(owner);
    id<MTLDevice> device =
        (id<MTLDevice>)(void*)borrowedDevice.get();
    if(device!=nil) {
      collectAppleFamilies(snapshot,device);
      collectMetalFamilies(snapshot,device);
      collectSpatialProbe(snapshot,device);
      collectTemporalProbe(snapshot,device);
      collectMeshProbe(snapshot,device);
      collectRayTracingProbe(snapshot,device);
      collectMetal4Probe(snapshot,device);
      collectLimits(snapshot,device);
    }
  }
#else
  (void)owner;
#endif

  return iosMapDeviceNativeSnapshot(snapshot);
  }

void iosLogDeviceFacts(
    const IOSDeviceFactsCreateResult& result) noexcept {
  try {
    logFacts(result);
  }
  catch(...) {
  }
  }
