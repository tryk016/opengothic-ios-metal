#pragma once

#include <cstdint>
#include <vector>

inline constexpr uint32_t IOSFramePlanABIVersion = 1u;

// P2.2a describes only logical identity, lifetime and content transitions.
// Format, extent, sample count, usage and physical aliasing belong to P2.2b.

struct IOSResourceId final {
  uint32_t value = 0u;

  constexpr explicit operator bool() const noexcept {
    return value!=0u;
    }

  friend bool operator==(IOSResourceId,IOSResourceId) = default;
  };

struct IOSPassId final {
  uint32_t value = 0u;

  constexpr explicit operator bool() const noexcept {
    return value!=0u;
    }

  friend bool operator==(IOSPassId,IOSPassId) = default;
  };

enum class IOSResourceKind : uint8_t {
  Texture               = 0,
  Buffer                = 1,
  AccelerationStructure = 2,
  };

enum class IOSResourceLifetime : uint8_t {
  External   = 0,
  Persistent = 1,
  PerFrame   = 2,
  Transient  = 3,
  };

enum class IOSInitialContent : uint8_t {
  Undefined = 0,
  Defined   = 1,
  };

enum class IOSPassKind : uint8_t {
  Render                     = 0,
  Compute                    = 1,
  Blit                       = 2,
  External                   = 3,
  AccelerationStructureBuild = 4,
  Present                    = 5,
  };

enum class IOSUseSemantic : uint8_t {
  Read                             = 0,
  FullOverwrite                    = 1,
  ReadWrite                        = 2,
  RenderAttachment                 = 3,
  AccelerationStructureBuildOutput = 4,
  PresentSource                    = 5,
  };

enum class IOSLoadAction : uint8_t {
  NotApplicable = 0,
  Load          = 1,
  Clear         = 2,
  Discard       = 3,
  };

enum class IOSStoreAction : uint8_t {
  NotApplicable = 0,
  Store         = 1,
  Discard       = 2,
  };

struct IOSResourceDesc final {
  IOSResourceId       id;
  IOSResourceKind     kind = IOSResourceKind::Texture;
  IOSResourceLifetime lifetime = IOSResourceLifetime::External;
  IOSInitialContent   initialContent = IOSInitialContent::Undefined;
  bool                memoryless = false;
  bool                aliasable = false;
  };

struct IOSResourceUse final {
  IOSResourceId       resource;
  IOSUseSemantic      semantic = IOSUseSemantic::Read;
  IOSLoadAction       load = IOSLoadAction::NotApplicable;
  IOSStoreAction      store = IOSStoreAction::NotApplicable;
  };

struct IOSPassDesc final {
  IOSPassId                  id;
  IOSPassKind                kind = IOSPassKind::Render;
  std::vector<IOSResourceUse> uses;
  };

enum class IOSFramePlanError : uint8_t {
  None                             = 0,
  ResourceIdZero                   = 1,
  DuplicateResourceId              = 2,
  ResourceIdsNotIncreasing         = 3,
  UnknownResourceKind              = 4,
  UnknownResourceLifetime          = 5,
  UnknownInitialContent            = 6,
  InvalidInitialContentForLifetime = 7,
  InvalidAliasableResource         = 8,
  InvalidMemorylessResource        = 9,
  PassIdZero                       = 10,
  DuplicatePassId                  = 11,
  PassIdsNotIncreasing             = 12,
  UnknownPassKind                  = 13,
  EmptyPass                        = 14,
  UseResourceIdZero                = 15,
  DuplicateUse                     = 16,
  UsesNotIncreasing                = 17,
  UnknownResource                  = 18,
  UnknownUseSemantic               = 19,
  UnknownLoadAction                = 20,
  UnknownStoreAction               = 21,
  MissingPresent                   = 22,
  MultiplePresent                  = 23,
  PresentNotLast                   = 24,
  IncompatiblePassUse              = 25,
  IncompatibleResourceUse          = 26,
  InvalidLoadStore                 = 27,
  InvalidPresentUse                = 28,
  InvalidPresentResource           = 29,
  UnusedResource                   = 30,
  InvalidMemorylessUse             = 31,
  ReadBeforeWrite                  = 32,
  ReadAfterDiscard                 = 33,
  PresentUndefined                 = 34,
  };

struct IOSFramePlanValidation final {
  IOSFramePlanError error = IOSFramePlanError::None;
  IOSPassId         pass;
  IOSResourceId     resource;

  explicit operator bool() const noexcept {
    return error==IOSFramePlanError::None;
    }
  };

struct IOSResourceUseRange final {
  IOSPassId first;
  IOSPassId last;

  explicit operator bool() const noexcept {
    return bool(first);
    }
  };

class IOSFramePlan final {
  public:
    std::vector<IOSResourceDesc> resources;
    std::vector<IOSPassDesc>     passes;

    IOSFramePlanValidation validate() const noexcept;
    IOSResourceUseRange useRange(IOSResourceId resource) const noexcept;
  };
