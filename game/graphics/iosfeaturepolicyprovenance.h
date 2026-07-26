#pragma once

#include "iosfeaturepolicy.h"

#include <cstddef>
#include <cstdint>
#include <type_traits>

inline constexpr uint32_t IOSFeaturePolicyProvenanceSchemaVersion = 1u;

struct IOSFeatureActivationResults final {
  bool metalFxSpatial;
  bool metalFxTemporal;
  bool meshShading;
  bool rayTracing;
  bool metal4Transport;
  };

struct IOSFeaturePolicyDecision final {
  IOSFeatureId feature;
  IOSDeviceProbeId probe;
  IOSFeaturePolicyState state;
  };

struct IOSFeaturePolicyProvenanceStorage final {
  uint32_t factsAbiVersion;
  uint32_t probeContractVersion;
  IOSFeaturePolicyDecision decisions[5];
  IOSFeatureDefaultClass defaults;
  uint8_t reserved;
  };

class IOSFeaturePolicyProvenance final {
  public:
    IOSFeaturePolicyProvenance() = delete;
    IOSFeaturePolicyProvenance(
        const IOSFeaturePolicyProvenance&) noexcept = default;
    IOSFeaturePolicyProvenance(
        IOSFeaturePolicyProvenance&&) noexcept = default;
    IOSFeaturePolicyProvenance& operator=(
        const IOSFeaturePolicyProvenance&) noexcept = default;
    IOSFeaturePolicyProvenance& operator=(
        IOSFeaturePolicyProvenance&&) noexcept = default;

    IOSFeatureDefaultClass defaults() const noexcept;
    uint32_t factsAbiVersion() const noexcept;
    uint32_t probeContractVersion() const noexcept;
    const IOSFeaturePolicyDecision* decision(
        IOSFeatureId feature) const noexcept;

  private:
    friend IOSFeaturePolicyProvenance iosBuildFeaturePolicyProvenance(
        const IOSDeviceFacts&,
        IOSFeatureDefaultClass,
        IOSFeatureActivationResults) noexcept;
    explicit IOSFeaturePolicyProvenance(
        IOSFeaturePolicyProvenanceStorage storage) noexcept;

  private:
    IOSFeaturePolicyProvenanceStorage storage_;
  };

IOSFeaturePolicyProvenance iosBuildFeaturePolicyProvenance(
    const IOSDeviceFacts& facts,
    IOSFeatureDefaultClass defaults,
    IOSFeatureActivationResults activation) noexcept;

enum class IOSFeatureTelemetryResult : uint8_t {
  Emitted = 0u,
  AlreadyEmitted = 1u,
  BufferTooSmall = 2u,
  };

inline constexpr size_t IOSFeaturePolicyTelemetryCapacity = 295u;

struct IOSFeatureTelemetryGate final {
  bool emitted = false;
  };

IOSFeatureTelemetryResult iosTakeFeaturePolicyTelemetry(
    IOSFeatureTelemetryGate& gate,
    const IOSFeaturePolicyProvenance& provenance,
    char* output,
    size_t capacity) noexcept;

static_assert(sizeof(IOSFeatureActivationResults)==5u);
static_assert(alignof(IOSFeatureActivationResults)==1u);
static_assert(std::is_standard_layout_v<IOSFeatureActivationResults>);
static_assert(std::is_trivially_copyable_v<IOSFeatureActivationResults>);
static_assert(offsetof(IOSFeatureActivationResults,metalFxSpatial)==0u);
static_assert(offsetof(IOSFeatureActivationResults,metalFxTemporal)==1u);
static_assert(offsetof(IOSFeatureActivationResults,meshShading)==2u);
static_assert(offsetof(IOSFeatureActivationResults,rayTracing)==3u);
static_assert(offsetof(IOSFeatureActivationResults,metal4Transport)==4u);

static_assert(sizeof(IOSFeaturePolicyDecision)==6u);
static_assert(alignof(IOSFeaturePolicyDecision)==1u);
static_assert(std::is_standard_layout_v<IOSFeaturePolicyDecision>);
static_assert(std::is_trivially_copyable_v<IOSFeaturePolicyDecision>);
static_assert(offsetof(IOSFeaturePolicyDecision,feature)==0u);
static_assert(offsetof(IOSFeaturePolicyDecision,probe)==1u);
static_assert(offsetof(IOSFeaturePolicyDecision,state)==2u);

static_assert(sizeof(IOSFeaturePolicyProvenanceStorage)==40u);
static_assert(alignof(IOSFeaturePolicyProvenanceStorage)==4u);
static_assert(
    std::is_standard_layout_v<IOSFeaturePolicyProvenanceStorage>);
static_assert(
    std::is_trivially_copyable_v<IOSFeaturePolicyProvenanceStorage>);
static_assert(
    offsetof(IOSFeaturePolicyProvenanceStorage,factsAbiVersion)==0u);
static_assert(
    offsetof(IOSFeaturePolicyProvenanceStorage,probeContractVersion)==4u);
static_assert(offsetof(
    IOSFeaturePolicyProvenanceStorage,decisions)==8u);
static_assert(
    offsetof(IOSFeaturePolicyProvenanceStorage,defaults)==38u);
static_assert(
    offsetof(IOSFeaturePolicyProvenanceStorage,reserved)==39u);

static_assert(sizeof(IOSFeaturePolicyProvenance)==40u);
static_assert(alignof(IOSFeaturePolicyProvenance)==4u);
static_assert(std::is_standard_layout_v<IOSFeaturePolicyProvenance>);
static_assert(std::is_trivially_copyable_v<IOSFeaturePolicyProvenance>);
static_assert(!std::is_default_constructible_v<
    IOSFeaturePolicyProvenance>);
static_assert(std::is_nothrow_copy_constructible_v<
    IOSFeaturePolicyProvenance>);
static_assert(std::is_nothrow_move_constructible_v<
    IOSFeaturePolicyProvenance>);
static_assert(std::is_nothrow_copy_assignable_v<
    IOSFeaturePolicyProvenance>);
static_assert(std::is_nothrow_move_assignable_v<
    IOSFeaturePolicyProvenance>);

static_assert(static_cast<uint8_t>(
    IOSFeatureTelemetryResult::Emitted)==0u);
static_assert(static_cast<uint8_t>(
    IOSFeatureTelemetryResult::AlreadyEmitted)==1u);
static_assert(static_cast<uint8_t>(
    IOSFeatureTelemetryResult::BufferTooSmall)==2u);
static_assert(sizeof(IOSFeatureTelemetryGate)==1u);
static_assert(alignof(IOSFeatureTelemetryGate)==1u);
static_assert(std::is_standard_layout_v<IOSFeatureTelemetryGate>);
static_assert(std::is_trivially_copyable_v<IOSFeatureTelemetryGate>);
static_assert(offsetof(IOSFeatureTelemetryGate,emitted)==0u);
