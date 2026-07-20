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
     presentResource->lifetime!=IOSResourceLifetime::External)
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
