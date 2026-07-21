#include "iosframeplan.h"

#include <cstddef>

namespace {

IOSFramePlanValidation failure(IOSFramePlanError error,
                               IOSPassId pass = {},
                               IOSResourceId resource = {}) noexcept {
  return {error,pass,resource};
  }

bool valid(IOSResourceKind value) noexcept {
  switch(value) {
    case IOSResourceKind::Texture:
    case IOSResourceKind::Buffer:
    case IOSResourceKind::AccelerationStructure:
      return true;
    }
  return false;
  }

bool valid(IOSResourceLifetime value) noexcept {
  switch(value) {
    case IOSResourceLifetime::External:
    case IOSResourceLifetime::Persistent:
    case IOSResourceLifetime::PerFrame:
    case IOSResourceLifetime::Transient:
      return true;
    }
  return false;
  }

bool valid(IOSInitialContent value) noexcept {
  switch(value) {
    case IOSInitialContent::Undefined:
    case IOSInitialContent::Defined:
      return true;
    }
  return false;
  }

bool valid(IOSPixelFormat value) noexcept {
  switch(value) {
    case IOSPixelFormat::Undefined:
    case IOSPixelFormat::R8Unorm:
    case IOSPixelFormat::R16Float:
    case IOSPixelFormat::R32Float:
    case IOSPixelFormat::R32Uint:
    case IOSPixelFormat::Rg16Float:
    case IOSPixelFormat::Rg32Uint:
    case IOSPixelFormat::Rgba8Unorm:
    case IOSPixelFormat::Bgra8Unorm:
    case IOSPixelFormat::Rg11B10Float:
    case IOSPixelFormat::Rgba16Float:
    case IOSPixelFormat::Depth16Unorm:
    case IOSPixelFormat::Depth32Float:
    case IOSPixelFormat::Bc1Rgba:
    case IOSPixelFormat::Bc2Rgba:
    case IOSPixelFormat::Bc3Rgba:
      return true;
    }
  return false;
  }

bool isBlockCompressed(IOSPixelFormat value) noexcept {
  return value==IOSPixelFormat::Bc1Rgba ||
         value==IOSPixelFormat::Bc2Rgba ||
         value==IOSPixelFormat::Bc3Rgba;
  }

bool isDepth(IOSPixelFormat value) noexcept {
  return value==IOSPixelFormat::Depth16Unorm ||
         value==IOSPixelFormat::Depth32Float;
  }

uint32_t maximumMipLevels(IOSExtent2D extent) noexcept {
  uint32_t maximum = extent.width>extent.height
                   ? extent.width
                   : extent.height;
  uint32_t levels = 0u;
  while(maximum!=0u) {
    ++levels;
    maximum /= 2u;
    }
  return levels;
  }

constexpr uint32_t knownUsageMask =
    static_cast<uint32_t>(IOSResourceUsage::ShaderRead) |
    static_cast<uint32_t>(IOSResourceUsage::ShaderWrite) |
    static_cast<uint32_t>(IOSResourceUsage::RenderAttachment) |
    static_cast<uint32_t>(IOSResourceUsage::BlitSource) |
    static_cast<uint32_t>(IOSResourceUsage::BlitDestination) |
    static_cast<uint32_t>(IOSResourceUsage::Present) |
    static_cast<uint32_t>(IOSResourceUsage::ExternalRead) |
    static_cast<uint32_t>(IOSResourceUsage::ExternalWrite) |
    static_cast<uint32_t>(IOSResourceUsage::AccelerationStructureBuildInput) |
    static_cast<uint32_t>(IOSResourceUsage::AccelerationStructureBuildOutput);

bool valid(IOSPassKind value) noexcept {
  switch(value) {
    case IOSPassKind::Render:
    case IOSPassKind::Compute:
    case IOSPassKind::Blit:
    case IOSPassKind::External:
    case IOSPassKind::AccelerationStructureBuild:
    case IOSPassKind::Present:
      return true;
    }
  return false;
  }

bool valid(IOSUseSemantic value) noexcept {
  switch(value) {
    case IOSUseSemantic::Read:
    case IOSUseSemantic::FullOverwrite:
    case IOSUseSemantic::ReadWrite:
    case IOSUseSemantic::RenderAttachment:
    case IOSUseSemantic::AccelerationStructureBuildOutput:
    case IOSUseSemantic::PresentSource:
      return true;
    }
  return false;
  }

bool valid(IOSLoadAction value) noexcept {
  switch(value) {
    case IOSLoadAction::NotApplicable:
    case IOSLoadAction::Load:
    case IOSLoadAction::Clear:
    case IOSLoadAction::Discard:
      return true;
    }
  return false;
  }

bool valid(IOSStoreAction value) noexcept {
  switch(value) {
    case IOSStoreAction::NotApplicable:
    case IOSStoreAction::Store:
    case IOSStoreAction::Discard:
      return true;
    }
  return false;
  }

const IOSResourceDesc* findResource(
    const std::vector<IOSResourceDesc>& resources,
    IOSResourceId id) noexcept {
  for(const auto& resource:resources)
    if(resource.id==id)
      return &resource;
  return nullptr;
  }

bool compatible(IOSPassKind pass, IOSUseSemantic use) noexcept {
  switch(pass) {
    case IOSPassKind::Render:
      return use==IOSUseSemantic::Read ||
             use==IOSUseSemantic::RenderAttachment;
    case IOSPassKind::Compute:
    case IOSPassKind::Blit:
    case IOSPassKind::External:
      return use==IOSUseSemantic::Read ||
             use==IOSUseSemantic::FullOverwrite ||
             use==IOSUseSemantic::ReadWrite;
    case IOSPassKind::AccelerationStructureBuild:
      return use==IOSUseSemantic::Read ||
             use==IOSUseSemantic::AccelerationStructureBuildOutput;
    case IOSPassKind::Present:
      return use==IOSUseSemantic::PresentSource;
    }
  return false;
  }

IOSResourceUsage requiredUsage(IOSPassKind pass,
                               IOSUseSemantic use) noexcept {
  switch(pass) {
    case IOSPassKind::Render:
      if(use==IOSUseSemantic::Read)
        return IOSResourceUsage::ShaderRead;
      if(use==IOSUseSemantic::RenderAttachment)
        return IOSResourceUsage::RenderAttachment;
      break;
    case IOSPassKind::Compute:
      if(use==IOSUseSemantic::Read)
        return IOSResourceUsage::ShaderRead;
      if(use==IOSUseSemantic::FullOverwrite)
        return IOSResourceUsage::ShaderWrite;
      if(use==IOSUseSemantic::ReadWrite)
        return IOSResourceUsage::ShaderRead|IOSResourceUsage::ShaderWrite;
      break;
    case IOSPassKind::Blit:
      if(use==IOSUseSemantic::Read)
        return IOSResourceUsage::BlitSource;
      if(use==IOSUseSemantic::FullOverwrite)
        return IOSResourceUsage::BlitDestination;
      if(use==IOSUseSemantic::ReadWrite)
        return IOSResourceUsage::BlitSource|
               IOSResourceUsage::BlitDestination;
      break;
    case IOSPassKind::External:
      if(use==IOSUseSemantic::Read)
        return IOSResourceUsage::ExternalRead;
      if(use==IOSUseSemantic::FullOverwrite)
        return IOSResourceUsage::ExternalWrite;
      if(use==IOSUseSemantic::ReadWrite)
        return IOSResourceUsage::ExternalRead|
               IOSResourceUsage::ExternalWrite;
      break;
    case IOSPassKind::AccelerationStructureBuild:
      if(use==IOSUseSemantic::Read)
        return IOSResourceUsage::AccelerationStructureBuildInput;
      if(use==IOSUseSemantic::AccelerationStructureBuildOutput)
        return IOSResourceUsage::AccelerationStructureBuildOutput;
      break;
    case IOSPassKind::Present:
      if(use==IOSUseSemantic::PresentSource)
        return IOSResourceUsage::Present;
      break;
    }
  return IOSResourceUsage::None;
  }

bool requiresDefinedContent(IOSUseSemantic semantic,
                            IOSLoadAction load) noexcept {
  return semantic==IOSUseSemantic::Read ||
         semantic==IOSUseSemantic::ReadWrite ||
         semantic==IOSUseSemantic::PresentSource ||
         (semantic==IOSUseSemantic::RenderAttachment &&
          load==IOSLoadAction::Load);
  }

}

IOSResourceUseRange IOSFramePlan::useRange(
    IOSResourceId resource) const noexcept {
  IOSResourceUseRange range;
  if(findResource(resources,resource)==nullptr)
    return range;
  for(const auto& pass:passes) {
    for(const auto& use:pass.uses) {
      if(use.resource!=resource)
        continue;
      if(!range.first)
        range.first = pass.id;
      range.last = pass.id;
      }
    }
  return range;
  }

IOSFramePlanValidation IOSFramePlan::validate() const noexcept {
  IOSResourceId previousResource;
  for(const auto& resource:resources) {
    if(!resource.id)
      return failure(IOSFramePlanError::ResourceIdZero,{},resource.id);
    if(resource.id.value<=previousResource.value) {
      for(const auto& earlier:resources) {
        if(&earlier==&resource)
          break;
        if(earlier.id==resource.id)
          return failure(IOSFramePlanError::DuplicateResourceId,{},resource.id);
        }
      return failure(IOSFramePlanError::ResourceIdsNotIncreasing,{},resource.id);
      }
    previousResource = resource.id;
    if(!valid(resource.kind))
      return failure(IOSFramePlanError::UnknownResourceKind,{},resource.id);
    if(!valid(resource.lifetime))
      return failure(IOSFramePlanError::UnknownResourceLifetime,{},resource.id);
    if(!valid(resource.initialContent))
      return failure(IOSFramePlanError::UnknownInitialContent,{},resource.id);
    if((resource.lifetime==IOSResourceLifetime::PerFrame ||
        resource.lifetime==IOSResourceLifetime::Transient) &&
       resource.initialContent!=IOSInitialContent::Undefined)
      return failure(IOSFramePlanError::InvalidInitialContentForLifetime,
                     {},resource.id);
    if(resource.aliasable &&
       resource.lifetime!=IOSResourceLifetime::Transient)
      return failure(IOSFramePlanError::InvalidAliasableResource,{},resource.id);
    if(resource.memoryless &&
       (resource.kind!=IOSResourceKind::Texture ||
        resource.lifetime!=IOSResourceLifetime::Transient ||
        resource.aliasable))
      return failure(IOSFramePlanError::InvalidMemorylessResource,{},resource.id);

    if(!valid(resource.layout.format))
      return failure(IOSFramePlanError::UnknownFormat,{},resource.id);
    const uint32_t usage = static_cast<uint32_t>(resource.usage);
    if(usage==0u)
      return failure(IOSFramePlanError::EmptyUsage,{},resource.id);
    if((usage&~knownUsageMask)!=0u)
      return failure(IOSFramePlanError::UnknownUsage,{},resource.id);

    if(resource.kind==IOSResourceKind::Texture) {
      const auto& layout = resource.layout;
      if(layout.format==IOSPixelFormat::Undefined ||
         layout.extent.width==0u || layout.extent.height==0u ||
         layout.mipLevels==0u ||
         layout.mipLevels>maximumMipLevels(layout.extent) ||
         layout.byteSize!=0u)
        return failure(IOSFramePlanError::InvalidTextureLayout,{},resource.id);
      if(layout.sampleCount!=1u && layout.sampleCount!=2u &&
         layout.sampleCount!=4u && layout.sampleCount!=8u)
        return failure(IOSFramePlanError::InvalidMultisample,{},resource.id);
      if(layout.sampleCount>1u &&
         (layout.mipLevels!=1u ||
          !iosHasUsage(resource.usage,IOSResourceUsage::RenderAttachment) ||
          iosHasUsage(resource.usage,IOSResourceUsage::ShaderWrite) ||
          iosHasUsage(resource.usage,IOSResourceUsage::Present)))
        return failure(IOSFramePlanError::InvalidMultisample,{},resource.id);
      if(isBlockCompressed(layout.format) && layout.sampleCount!=1u)
        return failure(IOSFramePlanError::InvalidMultisample,{},resource.id);

      const IOSResourceUsage forbiddenTexture =
          IOSResourceUsage::AccelerationStructureBuildInput |
          IOSResourceUsage::AccelerationStructureBuildOutput;
      const IOSResourceUsage forbiddenBc =
          IOSResourceUsage::RenderAttachment |
          IOSResourceUsage::ShaderWrite |
          IOSResourceUsage::Present;
      const IOSResourceUsage forbiddenDepth =
          IOSResourceUsage::ShaderWrite |
          IOSResourceUsage::Present;
      if((resource.usage&forbiddenTexture)!=IOSResourceUsage::None ||
         (isBlockCompressed(layout.format) &&
          (resource.usage&forbiddenBc)!=IOSResourceUsage::None) ||
         (isDepth(layout.format) &&
          (resource.usage&forbiddenDepth)!=IOSResourceUsage::None))
        return failure(IOSFramePlanError::IncompatibleFormatUsage,
                       {},resource.id);
      }
    else if(resource.kind==IOSResourceKind::Buffer) {
      const auto& layout = resource.layout;
      if(layout.format!=IOSPixelFormat::Undefined ||
         layout.extent.width!=0u || layout.extent.height!=0u ||
         layout.mipLevels!=0u || layout.sampleCount!=0u ||
         layout.byteSize==0u)
        return failure(IOSFramePlanError::InvalidBufferLayout,{},resource.id);
      const IOSResourceUsage forbiddenBuffer =
          IOSResourceUsage::RenderAttachment |
          IOSResourceUsage::Present |
          IOSResourceUsage::AccelerationStructureBuildOutput;
      if((resource.usage&forbiddenBuffer)!=IOSResourceUsage::None)
        return failure(IOSFramePlanError::IncompatibleFormatUsage,
                       {},resource.id);
      }
    else {
      const auto& layout = resource.layout;
      if(layout.format!=IOSPixelFormat::Undefined ||
         layout.extent.width!=0u || layout.extent.height!=0u ||
         layout.mipLevels!=0u || layout.sampleCount!=0u ||
         layout.byteSize!=0u)
        return failure(
            IOSFramePlanError::InvalidAccelerationStructureLayout,
            {},resource.id);
      const IOSResourceUsage forbiddenAccelerationStructure =
          IOSResourceUsage::ShaderWrite |
          IOSResourceUsage::RenderAttachment |
          IOSResourceUsage::BlitSource |
          IOSResourceUsage::BlitDestination |
          IOSResourceUsage::Present;
      if((resource.usage&forbiddenAccelerationStructure)!=
           IOSResourceUsage::None)
        return failure(IOSFramePlanError::IncompatibleFormatUsage,
                       {},resource.id);
      }

    if(iosHasUsage(resource.usage,IOSResourceUsage::Present) &&
       (resource.kind!=IOSResourceKind::Texture ||
        resource.lifetime!=IOSResourceLifetime::External ||
        resource.layout.mipLevels!=1u ||
        resource.layout.sampleCount!=1u ||
        isBlockCompressed(resource.layout.format) ||
        isDepth(resource.layout.format)))
      return failure(IOSFramePlanError::IncompatibleFormatUsage,
                     {},resource.id);

    if(resource.memoryless &&
       (resource.usage!=IOSResourceUsage::RenderAttachment ||
        resource.layout.mipLevels!=1u))
      return failure(IOSFramePlanError::InvalidMemorylessResource,
                     {},resource.id);
    }

  IOSPassId previousPass;
  for(const auto& pass:passes) {
    if(!pass.id)
      return failure(IOSFramePlanError::PassIdZero,pass.id);
    if(pass.id.value<=previousPass.value) {
      for(const auto& earlier:passes) {
        if(&earlier==&pass)
          break;
        if(earlier.id==pass.id)
          return failure(IOSFramePlanError::DuplicatePassId,pass.id);
        }
      return failure(IOSFramePlanError::PassIdsNotIncreasing,pass.id);
      }
    previousPass = pass.id;
    if(!valid(pass.kind))
      return failure(IOSFramePlanError::UnknownPassKind,pass.id);
    if(pass.uses.empty())
      return failure(IOSFramePlanError::EmptyPass,pass.id);

    IOSResourceId previousUse;
    for(const auto& use:pass.uses) {
      if(!use.resource)
        return failure(IOSFramePlanError::UseResourceIdZero,pass.id,use.resource);
      if(use.resource.value<=previousUse.value) {
        for(const auto& earlier:pass.uses) {
          if(&earlier==&use)
            break;
          if(earlier.resource==use.resource)
            return failure(IOSFramePlanError::DuplicateUse,pass.id,use.resource);
          }
        return failure(IOSFramePlanError::UsesNotIncreasing,pass.id,use.resource);
        }
      previousUse = use.resource;
      if(findResource(resources,use.resource)==nullptr)
        return failure(IOSFramePlanError::UnknownResource,pass.id,use.resource);
      if(!valid(use.semantic))
        return failure(IOSFramePlanError::UnknownUseSemantic,pass.id,use.resource);
      if(!valid(use.load))
        return failure(IOSFramePlanError::UnknownLoadAction,pass.id,use.resource);
      if(!valid(use.store))
        return failure(IOSFramePlanError::UnknownStoreAction,pass.id,use.resource);
      }
    }

  const IOSPassDesc* present = nullptr;
  for(const auto& pass:passes) {
    if(pass.kind!=IOSPassKind::Present)
      continue;
    if(present!=nullptr)
      return failure(IOSFramePlanError::MultiplePresent,pass.id);
    present = &pass;
    }
  if(present==nullptr)
    return failure(IOSFramePlanError::MissingPresent);
  if(&passes.back()!=present)
    return failure(IOSFramePlanError::PresentNotLast,present->id);

  if(present->uses.size()!=1u ||
     present->uses.front().semantic!=IOSUseSemantic::PresentSource)
    return failure(IOSFramePlanError::InvalidPresentUse,present->id,
                   present->uses.front().resource);
  const auto& presentUse = present->uses.front();
  const auto* presentResource = findResource(resources,presentUse.resource);
  if(presentResource->kind!=IOSResourceKind::Texture ||
     presentResource->lifetime!=IOSResourceLifetime::External ||
     presentResource->layout.sampleCount!=1u ||
     presentResource->layout.mipLevels!=1u)
    return failure(IOSFramePlanError::InvalidPresentResource,
                   present->id,presentUse.resource);

  for(const auto& pass:passes) {
    for(const auto& use:pass.uses) {
      const auto* resource = findResource(resources,use.resource);
      if(!compatible(pass.kind,use.semantic))
        return failure(IOSFramePlanError::IncompatiblePassUse,
                       pass.id,use.resource);
      if((use.semantic==IOSUseSemantic::RenderAttachment ||
          use.semantic==IOSUseSemantic::PresentSource) &&
         resource->kind!=IOSResourceKind::Texture)
        return failure(IOSFramePlanError::IncompatibleResourceUse,
                       pass.id,use.resource);
      if(use.semantic==IOSUseSemantic::AccelerationStructureBuildOutput &&
         resource->kind!=IOSResourceKind::AccelerationStructure)
        return failure(IOSFramePlanError::IncompatibleResourceUse,
                       pass.id,use.resource);

      const bool attachment = use.semantic==IOSUseSemantic::RenderAttachment;
      if(attachment) {
        if(use.load==IOSLoadAction::NotApplicable ||
           use.store==IOSStoreAction::NotApplicable)
          return failure(IOSFramePlanError::InvalidLoadStore,
                         pass.id,use.resource);
        }
      else if(use.load!=IOSLoadAction::NotApplicable ||
              use.store!=IOSStoreAction::NotApplicable)
        return failure(IOSFramePlanError::InvalidLoadStore,
                       pass.id,use.resource);

      const IOSResourceUsage required = requiredUsage(pass.kind,use.semantic);
      const bool deferInvalidMemorylessUse =
          resource->memoryless &&
          (use.semantic!=IOSUseSemantic::RenderAttachment ||
           use.store!=IOSStoreAction::Discard);
      if(!iosHasUsage(resource->usage,required) &&
         !deferInvalidMemorylessUse)
        return failure(IOSFramePlanError::MissingDeclaredUsage,
                       pass.id,use.resource);

      }
    }

  for(const auto& resource:resources) {
    const auto range = useRange(resource.id);
    if(!range)
      return failure(IOSFramePlanError::UnusedResource,{},resource.id);

    if(resource.memoryless) {
      const IOSResourceUse* onlyUse = nullptr;
      IOSPassId onlyPass;
      std::size_t count = 0u;
      for(const auto& pass:passes) {
        for(const auto& use:pass.uses) {
          if(use.resource!=resource.id)
            continue;
          ++count;
          onlyUse = &use;
          onlyPass = pass.id;
          }
        }
      if(count!=1u || onlyUse==nullptr ||
         onlyUse->semantic!=IOSUseSemantic::RenderAttachment ||
         onlyUse->store!=IOSStoreAction::Discard)
        return failure(IOSFramePlanError::InvalidMemorylessUse,
                       onlyPass,resource.id);
      }

    bool defined = resource.initialContent==IOSInitialContent::Defined;
    bool discarded = false;
    for(const auto& pass:passes) {
      for(const auto& use:pass.uses) {
        if(use.resource!=resource.id)
          continue;
        if(requiresDefinedContent(use.semantic,use.load) && !defined) {
          if(use.semantic==IOSUseSemantic::PresentSource)
            return failure(IOSFramePlanError::PresentUndefined,
                           pass.id,resource.id);
          return failure(discarded
                           ? IOSFramePlanError::ReadAfterDiscard
                           : IOSFramePlanError::ReadBeforeWrite,
                         pass.id,resource.id);
          }
        if(use.semantic==IOSUseSemantic::FullOverwrite ||
           use.semantic==IOSUseSemantic::AccelerationStructureBuildOutput ||
           (use.semantic==IOSUseSemantic::RenderAttachment &&
            (use.load==IOSLoadAction::Clear ||
             use.load==IOSLoadAction::Discard))) {
          defined = true;
          discarded = false;
          }
        if(use.semantic==IOSUseSemantic::RenderAttachment &&
           use.store==IOSStoreAction::Discard) {
          defined = false;
          discarded = true;
          }
        }
      }
    }
  return {};
  }
