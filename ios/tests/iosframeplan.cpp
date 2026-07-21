#include "graphics/iosframeplan.h"

#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <type_traits>
#include <utility>

namespace {

IOSResourceDesc resource(
    uint32_t id,
    IOSResourceKind kind,
    IOSResourceLifetime lifetime,
    IOSInitialContent initial,
    bool memoryless = false,
    bool aliasable = false,
    uint32_t aliasGroup = 0u) {
  IOSResourceDesc result;
  result.id = IOSResourceId{id};
  result.kind = kind;
  result.lifetime = lifetime;
  result.initialContent = initial;
  result.memoryless = memoryless;
  result.aliasable = aliasable;
  result.aliasGroup = IOSAliasGroupId{aliasGroup};
  if(kind==IOSResourceKind::Texture) {
    result.layout = {IOSPixelFormat::Rgba8Unorm,{64u,64u},1u,1u,0u};
    result.usage = memoryless
                 ? IOSResourceUsage::RenderAttachment
                 : IOSResourceUsage::ShaderRead |
                   IOSResourceUsage::ShaderWrite |
                   IOSResourceUsage::RenderAttachment |
                   IOSResourceUsage::BlitSource |
                   IOSResourceUsage::BlitDestination |
                   IOSResourceUsage::ExternalRead |
                   IOSResourceUsage::ExternalWrite;
    if(!memoryless && lifetime==IOSResourceLifetime::External)
      result.usage = result.usage|IOSResourceUsage::Present;
    }
  else if(kind==IOSResourceKind::Buffer) {
    result.layout.byteSize = 4096u;
    result.usage = IOSResourceUsage::ShaderRead |
                   IOSResourceUsage::ShaderWrite |
                   IOSResourceUsage::BlitSource |
                   IOSResourceUsage::BlitDestination |
                   IOSResourceUsage::ExternalRead |
                   IOSResourceUsage::ExternalWrite |
                   IOSResourceUsage::AccelerationStructureBuildInput;
    }
  else if(kind==IOSResourceKind::AccelerationStructure) {
    result.usage = IOSResourceUsage::ExternalRead |
                   IOSResourceUsage::AccelerationStructureBuildInput |
                   IOSResourceUsage::AccelerationStructureBuildOutput;
    }
  return result;
  }

IOSResourceUse use(
    uint32_t id,
    IOSUseSemantic semantic,
    IOSLoadAction load = IOSLoadAction::NotApplicable,
    IOSStoreAction store = IOSStoreAction::NotApplicable,
    IOSAttachmentWriteMode attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable) {
  return {IOSResourceId{id},semantic,load,store,attachmentWriteMode};
  }

IOSPassDesc pass(uint32_t id, IOSPassKind kind,
                 std::vector<IOSResourceUse> uses) {
  return {IOSPassId{id},kind,std::move(uses)};
  }

IOSFramePlan validPlan() {
  IOSFramePlan plan;
  plan.resources = {
    resource(1u,IOSResourceKind::Texture,IOSResourceLifetime::External,
             IOSInitialContent::Undefined),
    resource(2u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
             IOSInitialContent::Undefined,true),
    };
  plan.passes = {
    pass(1u,IOSPassKind::Render,{
      use(1u,IOSUseSemantic::RenderAttachment,
          IOSLoadAction::Clear,IOSStoreAction::Store,
          IOSAttachmentWriteMode::MayPreserve),
      use(2u,IOSUseSemantic::RenderAttachment,
          IOSLoadAction::Discard,IOSStoreAction::Discard,
          IOSAttachmentWriteMode::MayPreserve),
      }),
    pass(2u,IOSPassKind::External,{
      use(1u,IOSUseSemantic::ReadWrite),
      }),
    pass(3u,IOSPassKind::Present,{
      use(1u,IOSUseSemantic::PresentSource),
      }),
    };
  return plan;
  }

void expect(const IOSFramePlan& plan, IOSFramePlanError error,
            uint32_t passId, uint32_t resourceId) {
  static uint32_t call = 0u;
  ++call;
  const auto result = plan.validate();
  if(result.error!=error || result.pass.value!=passId ||
     result.resource.value!=resourceId)
    std::fprintf(stderr,"call %u expected %u/%u/%u, got %u/%u/%u\n",call,
                 static_cast<unsigned>(error),passId,resourceId,
                 static_cast<unsigned>(result.error),result.pass.value,
                 result.resource.value);
  assert(result.error==error);
  assert(result.pass.value==passId);
  assert(result.resource.value==resourceId);
  }

IOSResourceUsage withoutUsage(IOSResourceUsage value,
                              IOSResourceUsage removed) {
  return static_cast<IOSResourceUsage>(
      static_cast<uint32_t>(value)&~static_cast<uint32_t>(removed));
  }

IOSFramePlan usagePlan(IOSPassKind kind, IOSUseSemantic semantic,
                       IOSResourceUsage declared) {
  auto plan = validPlan();
  IOSResourceDesc target;
  IOSResourceUse targetUse;
  if(semantic==IOSUseSemantic::RenderAttachment) {
    target = resource(3u,IOSResourceKind::Texture,
                      IOSResourceLifetime::Transient,
                      IOSInitialContent::Undefined);
    targetUse = use(3u,semantic,IOSLoadAction::Clear,IOSStoreAction::Store);
    targetUse.attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    }
  else if(semantic==IOSUseSemantic::AccelerationStructureBuildOutput) {
    target = resource(3u,IOSResourceKind::AccelerationStructure,
                      IOSResourceLifetime::Transient,
                      IOSInitialContent::Undefined);
    targetUse = use(3u,semantic);
    }
  else {
    target = resource(3u,IOSResourceKind::Buffer,
                      IOSResourceLifetime::Persistent,
                      IOSInitialContent::Defined);
    targetUse = use(3u,semantic);
    }
  target.usage = declared;
  plan.resources.push_back(target);
  plan.passes[2].id = IOSPassId{4u};
  plan.passes.insert(plan.passes.begin()+2,pass(3u,kind,{targetUse}));
  return plan;
  }

IOSFramePlan textureReadPlan(IOSPixelFormat format,
                             IOSResourceUsage usage) {
  auto plan = validPlan();
  auto texture = resource(3u,IOSResourceKind::Texture,
                          IOSResourceLifetime::Persistent,
                          IOSInitialContent::Defined);
  texture.layout.format = format;
  texture.usage = usage;
  plan.resources.push_back(texture);
  plan.passes[0].uses.push_back(use(3u,IOSUseSemantic::Read));
  return plan;
  }

IOSFramePlan textureBlitPlan(IOSPixelFormat format,
                             IOSResourceUsage usage) {
  auto plan = validPlan();
  auto texture = resource(3u,IOSResourceKind::Texture,
                          IOSResourceLifetime::Persistent,
                          IOSInitialContent::Defined);
  texture.layout.format = format;
  texture.usage = usage;
  plan.resources.push_back(texture);
  plan.passes[2].id = IOSPassId{4u};
  plan.passes.insert(plan.passes.begin()+2,pass(3u,IOSPassKind::Blit,{
    use(3u,IOSUseSemantic::ReadWrite),
    }));
  return plan;
  }

IOSFramePlan aliasRangePlan(
    const std::vector<std::vector<uint32_t>>& resourcePasses,
    const std::vector<uint32_t>& aliasGroups) {
  assert(resourcePasses.size()==aliasGroups.size());
  IOSFramePlan plan;
  plan.resources.push_back(
      resource(1u,IOSResourceKind::Texture,IOSResourceLifetime::External,
               IOSInitialContent::Defined));

  uint32_t resourceId = 2u;
  uint32_t maximumPass = 0u;
  for(std::size_t i=0u; i<resourcePasses.size(); ++i) {
    assert(!resourcePasses[i].empty());
    plan.resources.push_back(
        resource(resourceId,IOSResourceKind::Buffer,
                 IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined,false,true,aliasGroups[i]));
    ++resourceId;
    for(const uint32_t passId:resourcePasses[i]) {
      assert(passId!=0u);
      if(passId>maximumPass)
        maximumPass = passId;
      }
    }

  for(uint32_t passId=1u; passId<=maximumPass; ++passId) {
    std::vector<IOSResourceUse> uses;
    resourceId = 2u;
    for(const auto& resourceUses:resourcePasses) {
      for(const uint32_t usedPass:resourceUses) {
        if(usedPass!=passId)
          continue;
        const IOSUseSemantic semantic = resourceUses.front()==passId
                                      ? IOSUseSemantic::FullOverwrite
                                      : IOSUseSemantic::Read;
        uses.push_back(use(resourceId,semantic));
        break;
        }
      ++resourceId;
      }
    if(!uses.empty())
      plan.passes.push_back(pass(passId,IOSPassKind::Compute,std::move(uses)));
    }
  plan.passes.push_back(pass(maximumPass+1u,IOSPassKind::Present,{
    use(1u,IOSUseSemantic::PresentSource),
    }));
  return plan;
  }

IOSFramePlan aliasRangePlan(
    const std::vector<std::vector<uint32_t>>& resourcePasses,
    uint32_t aliasGroup) {
  return aliasRangePlan(
      resourcePasses,std::vector<uint32_t>(resourcePasses.size(),aliasGroup));
  }

IOSFramePlan attachmentContentPlan(
    IOSInitialContent initial,
    IOSLoadAction load,
    IOSAttachmentWriteMode attachmentWriteMode,
    IOSStoreAction store) {
  IOSFramePlan plan;
  plan.resources = {
    resource(1u,IOSResourceKind::Texture,IOSResourceLifetime::External,
             IOSInitialContent::Defined),
    resource(2u,IOSResourceKind::Texture,IOSResourceLifetime::Persistent,
             initial),
    };
  plan.resources[1].usage = IOSResourceUsage::RenderAttachment |
                            IOSResourceUsage::ExternalRead;
  plan.passes = {
    pass(1u,IOSPassKind::Render,{
      use(2u,IOSUseSemantic::RenderAttachment,load,store,
          attachmentWriteMode),
      }),
    pass(2u,IOSPassKind::External,{
      use(2u,IOSUseSemantic::Read),
      }),
    pass(3u,IOSPassKind::Present,{
      use(1u,IOSUseSemantic::PresentSource),
      }),
    };
  return plan;
  }

}

int main() {
  static_assert(IOSFramePlanABIVersion==4u);
  static_assert(sizeof(IOSResourceId)==sizeof(uint32_t));
  static_assert(sizeof(IOSPassId)==sizeof(uint32_t));
  static_assert(sizeof(IOSAliasGroupId)==sizeof(uint32_t));
  static_assert(std::is_same_v<decltype(IOSResourceDesc::aliasGroup),
                               IOSAliasGroupId>);
  static_assert(offsetof(IOSResourceDesc,aliasGroup)>
                offsetof(IOSResourceDesc,aliasable));
  static_assert(std::is_same_v<
      decltype(IOSResourceUse::attachmentWriteMode),
      IOSAttachmentWriteMode>);
  static_assert(offsetof(IOSResourceUse,attachmentWriteMode)>
                offsetof(IOSResourceUse,store));
  static_assert(IOSResourceUse{}.attachmentWriteMode==
                IOSAttachmentWriteMode::NotApplicable);
  static_assert(IOSResourceId{7u}==IOSResourceId{7u});
  static_assert(IOSPassId{9u}==IOSPassId{9u});
  static_assert(IOSAliasGroupId{11u}==IOSAliasGroupId{11u});
  static_assert(IOSAliasGroupId{11u}!=IOSAliasGroupId{12u});
  static_assert(bool(IOSResourceId{1u}));
  static_assert(!bool(IOSResourceId{}));
  static_assert(bool(IOSPassId{1u}));
  static_assert(!bool(IOSPassId{}));
  static_assert(bool(IOSAliasGroupId{1u}));
  static_assert(bool(IOSAliasGroupId{
      std::numeric_limits<uint32_t>::max()}));
  static_assert(!bool(IOSAliasGroupId{}));
#define IOS_ASSERT_ORDINAL(type,name,value) \
  static_assert(static_cast<uint8_t>(type::name)==value)
  IOS_ASSERT_ORDINAL(IOSResourceKind,Texture,0u);
  IOS_ASSERT_ORDINAL(IOSResourceKind,Buffer,1u);
  IOS_ASSERT_ORDINAL(IOSResourceKind,AccelerationStructure,2u);
  IOS_ASSERT_ORDINAL(IOSResourceLifetime,External,0u);
  IOS_ASSERT_ORDINAL(IOSResourceLifetime,Persistent,1u);
  IOS_ASSERT_ORDINAL(IOSResourceLifetime,PerFrame,2u);
  IOS_ASSERT_ORDINAL(IOSResourceLifetime,Transient,3u);
  IOS_ASSERT_ORDINAL(IOSInitialContent,Undefined,0u);
  IOS_ASSERT_ORDINAL(IOSInitialContent,Defined,1u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Undefined,0u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,R8Unorm,1u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,R16Float,2u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,R32Float,3u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,R32Uint,4u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Rg16Float,5u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Rg32Uint,6u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Rgba8Unorm,7u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Bgra8Unorm,8u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Rg11B10Float,9u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Rgba16Float,10u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Depth16Unorm,11u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Depth32Float,12u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Bc1Rgba,13u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Bc2Rgba,14u);
  IOS_ASSERT_ORDINAL(IOSPixelFormat,Bc3Rgba,15u);
  IOS_ASSERT_ORDINAL(IOSPassKind,Render,0u);
  IOS_ASSERT_ORDINAL(IOSPassKind,Compute,1u);
  IOS_ASSERT_ORDINAL(IOSPassKind,Blit,2u);
  IOS_ASSERT_ORDINAL(IOSPassKind,External,3u);
  IOS_ASSERT_ORDINAL(IOSPassKind,AccelerationStructureBuild,4u);
  IOS_ASSERT_ORDINAL(IOSPassKind,Present,5u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,Read,0u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,FullOverwrite,1u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,ReadWrite,2u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,RenderAttachment,3u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,AccelerationStructureBuildOutput,4u);
  IOS_ASSERT_ORDINAL(IOSUseSemantic,PresentSource,5u);
  IOS_ASSERT_ORDINAL(IOSLoadAction,NotApplicable,0u);
  IOS_ASSERT_ORDINAL(IOSLoadAction,Load,1u);
  IOS_ASSERT_ORDINAL(IOSLoadAction,Clear,2u);
  IOS_ASSERT_ORDINAL(IOSLoadAction,Discard,3u);
  IOS_ASSERT_ORDINAL(IOSStoreAction,NotApplicable,0u);
  IOS_ASSERT_ORDINAL(IOSStoreAction,Store,1u);
  IOS_ASSERT_ORDINAL(IOSStoreAction,Discard,2u);
  IOS_ASSERT_ORDINAL(IOSAttachmentWriteMode,NotApplicable,0u);
  IOS_ASSERT_ORDINAL(IOSAttachmentWriteMode,MayPreserve,1u);
  IOS_ASSERT_ORDINAL(IOSAttachmentWriteMode,FullOverwrite,2u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,None,0u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,ResourceIdZero,1u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,DuplicateResourceId,2u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,ResourceIdsNotIncreasing,3u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownResourceKind,4u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownResourceLifetime,5u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownInitialContent,6u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidInitialContentForLifetime,7u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidAliasableResource,8u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidMemorylessResource,9u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,PassIdZero,10u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,DuplicatePassId,11u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,PassIdsNotIncreasing,12u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownPassKind,13u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,EmptyPass,14u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UseResourceIdZero,15u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,DuplicateUse,16u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UsesNotIncreasing,17u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownResource,18u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownUseSemantic,19u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownLoadAction,20u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownStoreAction,21u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,MissingPresent,22u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,MultiplePresent,23u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,PresentNotLast,24u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,IncompatiblePassUse,25u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,IncompatibleResourceUse,26u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidLoadStore,27u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidPresentUse,28u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidPresentResource,29u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnusedResource,30u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidMemorylessUse,31u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,ReadBeforeWrite,32u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,ReadAfterDiscard,33u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,PresentUndefined,34u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownFormat,35u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,EmptyUsage,36u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownUsage,37u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidTextureLayout,38u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidBufferLayout,39u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidAccelerationStructureLayout,40u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,IncompatibleFormatUsage,41u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidMultisample,42u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,MissingDeclaredUsage,43u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidAliasGroupMember,44u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,SingletonAliasGroup,45u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,OverlappingAliasGroupUse,46u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,UnknownAttachmentWriteMode,47u);
  IOS_ASSERT_ORDINAL(IOSFramePlanError,InvalidAttachmentWriteMode,48u);
#undef IOS_ASSERT_ORDINAL

  static_assert(static_cast<uint32_t>(IOSResourceUsage::None)==0u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::ShaderRead)==1u<<0u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::ShaderWrite)==1u<<1u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::RenderAttachment)==1u<<2u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::BlitSource)==1u<<3u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::BlitDestination)==1u<<4u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::Present)==1u<<5u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::ExternalRead)==1u<<6u);
  static_assert(static_cast<uint32_t>(IOSResourceUsage::ExternalWrite)==1u<<7u);
  static_assert(static_cast<uint32_t>(
      IOSResourceUsage::AccelerationStructureBuildInput)==1u<<8u);
  static_assert(static_cast<uint32_t>(
      IOSResourceUsage::AccelerationStructureBuildOutput)==1u<<9u);

  const auto valid = validPlan();
  expect(valid,IOSFramePlanError::None,0u,0u);
  assert(valid.validate());
  const auto drawableRange = valid.useRange(IOSResourceId{1u});
  assert(drawableRange.first==IOSPassId{1u});
  assert(drawableRange.last==IOSPassId{3u});
  const auto depthRange = valid.useRange(IOSResourceId{2u});
  assert(depthRange.first==IOSPassId{1u});
  assert(depthRange.last==IOSPassId{1u});
  assert(!valid.useRange(IOSResourceId{99u}));

  {
    auto plan = validPlan();
    plan.passes[1].uses[0].resource = IOSResourceId{99u};
    assert(!plan.useRange(IOSResourceId{99u}));
  }

  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::External,
                 IOSInitialContent::Defined));
    plan.resources.push_back(
        resource(4u,IOSResourceKind::Buffer,IOSResourceLifetime::Persistent,
                 IOSInitialContent::Defined));
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    plan.passes[1].uses.push_back(use(4u,IOSUseSemantic::Read));
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined,false,true));
    plan.passes[0].uses.push_back(
        use(3u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Clear,IOSStoreAction::Discard,
            IOSAttachmentWriteMode::MayPreserve));
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::FullOverwrite));
    plan.passes[2] = pass(3u,IOSPassKind::External,{
      use(3u,IOSUseSemantic::Read),
      });
    plan.passes.push_back(pass(4u,IOSPassKind::Present,{
      use(1u,IOSUseSemantic::PresentSource),
      }));
    expect(plan,IOSFramePlanError::None,0u,0u);
    assert(plan.useRange(IOSResourceId{3u}).first==IOSPassId{1u});
    assert(plan.useRange(IOSResourceId{3u}).last==IOSPassId{3u});
  }

  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined));
    plan.passes[0].uses.push_back(
        use(3u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Discard,IOSStoreAction::Store,
            IOSAttachmentWriteMode::FullOverwrite));
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    const IOSInitialContent initialContents[] = {
      IOSInitialContent::Undefined,
      IOSInitialContent::Defined,
      };
    const IOSLoadAction loads[] = {
      IOSLoadAction::Clear,
      IOSLoadAction::Discard,
      IOSLoadAction::Load,
      };
    const IOSAttachmentWriteMode writeModes[] = {
      IOSAttachmentWriteMode::MayPreserve,
      IOSAttachmentWriteMode::FullOverwrite,
      };
    const IOSStoreAction stores[] = {
      IOSStoreAction::Store,
      IOSStoreAction::Discard,
      };
    for(const auto initial:initialContents) {
      for(const auto load:loads) {
        for(const auto writeMode:writeModes) {
          for(const auto store:stores) {
            const auto plan = attachmentContentPlan(
                initial,load,writeMode,store);
            if(initial==IOSInitialContent::Undefined &&
               load==IOSLoadAction::Load) {
              expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,2u);
              continue;
              }

            bool defined = initial==IOSInitialContent::Defined;
            if(load==IOSLoadAction::Clear)
              defined = true;
            else if(load==IOSLoadAction::Discard)
              defined = false;
            if(writeMode==IOSAttachmentWriteMode::FullOverwrite)
              defined = true;
            if(store==IOSStoreAction::Discard)
              defined = false;
            expect(plan,defined ? IOSFramePlanError::None
                                : IOSFramePlanError::ReadAfterDiscard,
                   defined ? 0u : 2u,defined ? 0u : 2u);
            }
          }
        }
      }
  }

  {
    IOSFramePlan plan;
    plan.resources = {
      resource(1u,IOSResourceKind::Texture,IOSResourceLifetime::External,
               IOSInitialContent::Undefined),
      resource(2u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
               IOSInitialContent::Undefined,true),
      resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::PerFrame,
               IOSInitialContent::Undefined),
      resource(4u,IOSResourceKind::Buffer,IOSResourceLifetime::Transient,
               IOSInitialContent::Undefined),
      resource(5u,IOSResourceKind::AccelerationStructure,
               IOSResourceLifetime::Transient,IOSInitialContent::Undefined),
      };
    plan.passes = {
      pass(1u,IOSPassKind::Render,{
        use(1u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Clear,IOSStoreAction::Store,
            IOSAttachmentWriteMode::MayPreserve),
        use(2u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Discard,IOSStoreAction::Discard,
            IOSAttachmentWriteMode::MayPreserve),
        }),
      pass(2u,IOSPassKind::Compute,{
        use(3u,IOSUseSemantic::FullOverwrite),
        }),
      pass(3u,IOSPassKind::Compute,{
        use(3u,IOSUseSemantic::Read),
        }),
      pass(4u,IOSPassKind::Blit,{
        use(3u,IOSUseSemantic::Read),
        use(4u,IOSUseSemantic::FullOverwrite),
        }),
      pass(5u,IOSPassKind::AccelerationStructureBuild,{
        use(4u,IOSUseSemantic::Read),
        use(5u,IOSUseSemantic::AccelerationStructureBuildOutput),
        }),
      pass(6u,IOSPassKind::External,{
        use(5u,IOSUseSemantic::Read),
        }),
      pass(7u,IOSPassKind::Present,{
        use(1u,IOSUseSemantic::PresentSource),
        }),
      };
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    const IOSPixelFormat formats[] = {
      IOSPixelFormat::R8Unorm,
      IOSPixelFormat::R16Float,
      IOSPixelFormat::R32Float,
      IOSPixelFormat::R32Uint,
      IOSPixelFormat::Rg16Float,
      IOSPixelFormat::Rg32Uint,
      IOSPixelFormat::Rgba8Unorm,
      IOSPixelFormat::Bgra8Unorm,
      IOSPixelFormat::Rg11B10Float,
      IOSPixelFormat::Rgba16Float,
      };
    for(const auto format:formats) {
      auto plan = validPlan();
      plan.resources[0].layout.format = format;
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    const uint32_t samples[] = {1u,2u,4u,8u};
    for(const uint32_t sampleCount:samples) {
      auto plan = usagePlan(IOSPassKind::Render,
                            IOSUseSemantic::RenderAttachment,
                            IOSResourceUsage::RenderAttachment);
      plan.resources[2].layout.sampleCount = sampleCount;
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    const IOSPixelFormat depths[] = {
      IOSPixelFormat::Depth16Unorm,
      IOSPixelFormat::Depth32Float,
      };
    for(const auto format:depths) {
      auto plan = usagePlan(IOSPassKind::Render,
                            IOSUseSemantic::RenderAttachment,
                            IOSResourceUsage::RenderAttachment);
      plan.resources[2].layout.format = format;
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    const IOSPixelFormat compressed[] = {
      IOSPixelFormat::Bc1Rgba,
      IOSPixelFormat::Bc2Rgba,
      IOSPixelFormat::Bc3Rgba,
      };
    for(const auto format:compressed) {
      const auto plan = textureReadPlan(format,IOSResourceUsage::ShaderRead);
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    const IOSPixelFormat compressed[] = {
      IOSPixelFormat::Bc1Rgba,
      IOSPixelFormat::Bc2Rgba,
      IOSPixelFormat::Bc3Rgba,
      };
    for(const auto format:compressed) {
      const auto plan = textureBlitPlan(
          format,IOSResourceUsage::BlitSource |
                 IOSResourceUsage::BlitDestination);
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    const IOSPixelFormat depths[] = {
      IOSPixelFormat::Depth16Unorm,
      IOSPixelFormat::Depth32Float,
      };
    for(const auto format:depths) {
      auto plan = textureBlitPlan(
          format,IOSResourceUsage::ShaderRead |
                 IOSResourceUsage::BlitSource |
                 IOSResourceUsage::BlitDestination);
      plan.passes[0].uses.push_back(use(3u,IOSUseSemantic::Read));
      expect(plan,IOSFramePlanError::None,0u,0u);
      }
  }

  {
    auto plan = usagePlan(
        IOSPassKind::Render,IOSUseSemantic::RenderAttachment,
        IOSResourceUsage::RenderAttachment|IOSResourceUsage::ShaderRead);
    plan.resources[2].layout.sampleCount = 4u;
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = usagePlan(
        IOSPassKind::Render,IOSUseSemantic::RenderAttachment,
        IOSResourceUsage::RenderAttachment|IOSResourceUsage::BlitSource);
    plan.resources[2].layout.sampleCount = 2u;
    plan.passes[3].id = IOSPassId{5u};
    plan.passes.insert(plan.passes.begin()+3,pass(4u,IOSPassKind::Blit,{
      use(3u,IOSUseSemantic::Read),
      }));
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::RenderAttachment|IOSResourceUsage::ShaderWrite,
      IOSResourceUsage::RenderAttachment|IOSResourceUsage::ShaderRead|
        IOSResourceUsage::ShaderWrite,
      };
    for(const auto usage:forbidden) {
      auto plan = usagePlan(
          IOSPassKind::Render,IOSUseSemantic::RenderAttachment,usage);
      plan.resources[2].layout.sampleCount = 2u;
      expect(plan,IOSFramePlanError::InvalidMultisample,0u,3u);
      }
  }

  {
    auto plan = usagePlan(
        IOSPassKind::AccelerationStructureBuild,IOSUseSemantic::Read,
        IOSResourceUsage::ExternalRead |
        IOSResourceUsage::AccelerationStructureBuildInput);
    plan.resources[2].layout.byteSize = 1u;
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = usagePlan(
        IOSPassKind::Compute,IOSUseSemantic::Read,
        IOSResourceUsage::ShaderRead);
    plan.resources[2].kind = IOSResourceKind::AccelerationStructure;
    plan.resources[2].layout = {};
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = textureReadPlan(
        IOSPixelFormat::Rgba8Unorm,IOSResourceUsage::ShaderRead);
    plan.resources[2].layout.extent = {
      std::numeric_limits<uint32_t>::max(),1u};
    plan.resources[2].layout.mipLevels = 32u;
    expect(plan,IOSFramePlanError::None,0u,0u);
    plan.resources[2].layout.mipLevels = 33u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,3u);
  }
  {
    auto plan = textureReadPlan(
        IOSPixelFormat::Rgba8Unorm,IOSResourceUsage::ShaderRead);
    plan.resources[2].layout.extent = {3u,1u};
    plan.resources[2].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::None,0u,0u);
    plan.resources[2].layout.mipLevels = 3u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,3u);
  }
  {
    auto plan = textureReadPlan(
        IOSPixelFormat::Rgba8Unorm,
        IOSResourceUsage::ShaderRead|IOSResourceUsage::RenderAttachment);
    plan.resources[2].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    auto plan = usagePlan(IOSPassKind::Render,
                          IOSUseSemantic::RenderAttachment,
                          IOSResourceUsage::RenderAttachment);
    plan.resources[2].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,3u,3u);
  }
  {
    auto plan = usagePlan(IOSPassKind::External,IOSUseSemantic::Read,
                          IOSResourceUsage::ExternalRead);
    plan.resources[2].layout.byteSize =
        std::numeric_limits<uint64_t>::max();
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  struct UsageCase final {
    IOSPassKind passKind;
    IOSUseSemantic semantic;
    IOSResourceUsage required;
    };
  const UsageCase usageCases[] = {
    {IOSPassKind::Render,IOSUseSemantic::Read,
     IOSResourceUsage::ShaderRead},
    {IOSPassKind::Render,IOSUseSemantic::RenderAttachment,
     IOSResourceUsage::RenderAttachment},
    {IOSPassKind::Compute,IOSUseSemantic::Read,
     IOSResourceUsage::ShaderRead},
    {IOSPassKind::Compute,IOSUseSemantic::FullOverwrite,
     IOSResourceUsage::ShaderWrite},
    {IOSPassKind::Compute,IOSUseSemantic::ReadWrite,
     IOSResourceUsage::ShaderRead|IOSResourceUsage::ShaderWrite},
    {IOSPassKind::Blit,IOSUseSemantic::Read,
     IOSResourceUsage::BlitSource},
    {IOSPassKind::Blit,IOSUseSemantic::FullOverwrite,
     IOSResourceUsage::BlitDestination},
    {IOSPassKind::Blit,IOSUseSemantic::ReadWrite,
     IOSResourceUsage::BlitSource|IOSResourceUsage::BlitDestination},
    {IOSPassKind::External,IOSUseSemantic::Read,
     IOSResourceUsage::ExternalRead},
    {IOSPassKind::External,IOSUseSemantic::FullOverwrite,
     IOSResourceUsage::ExternalWrite},
    {IOSPassKind::External,IOSUseSemantic::ReadWrite,
     IOSResourceUsage::ExternalRead|IOSResourceUsage::ExternalWrite},
    {IOSPassKind::AccelerationStructureBuild,IOSUseSemantic::Read,
     IOSResourceUsage::AccelerationStructureBuildInput},
    {IOSPassKind::AccelerationStructureBuild,
     IOSUseSemantic::AccelerationStructureBuildOutput,
     IOSResourceUsage::AccelerationStructureBuildOutput},
    };
  const IOSResourceUsage usageBits[] = {
    IOSResourceUsage::ShaderRead,
    IOSResourceUsage::ShaderWrite,
    IOSResourceUsage::RenderAttachment,
    IOSResourceUsage::BlitSource,
    IOSResourceUsage::BlitDestination,
    IOSResourceUsage::ExternalRead,
    IOSResourceUsage::ExternalWrite,
    IOSResourceUsage::AccelerationStructureBuildInput,
    IOSResourceUsage::AccelerationStructureBuildOutput,
    };
  for(const auto& item:usageCases) {
    const auto accepted = usagePlan(item.passKind,item.semantic,item.required);
    expect(accepted,IOSFramePlanError::None,0u,0u);
    for(const auto bit:usageBits) {
      if(!iosHasUsage(item.required,bit))
        continue;
      auto declared = withoutUsage(item.required,bit);
      if(declared==IOSResourceUsage::None) {
        if(item.semantic==IOSUseSemantic::RenderAttachment)
          declared = IOSResourceUsage::ShaderRead;
        else if(item.semantic==
                  IOSUseSemantic::AccelerationStructureBuildOutput)
          declared = IOSResourceUsage::ExternalRead;
        else
          declared = IOSResourceUsage::ShaderRead==bit
                   ? IOSResourceUsage::ExternalRead
                   : IOSResourceUsage::ShaderRead;
        }
      const auto missing = usagePlan(item.passKind,item.semantic,declared);
      expect(missing,IOSFramePlanError::MissingDeclaredUsage,3u,3u);
      }
  }

  {
    auto plan = validPlan();
    plan.resources[0].usage = withoutUsage(
        plan.resources[0].usage,IOSResourceUsage::Present);
    expect(plan,IOSFramePlanError::MissingDeclaredUsage,3u,1u);
  }
  {
    const IOSResourceUsage allKnown =
        IOSResourceUsage::ShaderRead |
        IOSResourceUsage::ShaderWrite |
        IOSResourceUsage::BlitSource |
        IOSResourceUsage::BlitDestination |
        IOSResourceUsage::ExternalRead |
        IOSResourceUsage::ExternalWrite |
        IOSResourceUsage::AccelerationStructureBuildInput;
    const auto plan = usagePlan(
        IOSPassKind::Compute,IOSUseSemantic::ReadWrite,allKnown);
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = validPlan();
    plan.resources[0].layout.format = static_cast<IOSPixelFormat>(255u);
    expect(plan,IOSFramePlanError::UnknownFormat,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].usage = IOSResourceUsage::None;
    expect(plan,IOSFramePlanError::EmptyUsage,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].usage = static_cast<IOSResourceUsage>(1u<<10u);
    expect(plan,IOSFramePlanError::UnknownUsage,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].usage = static_cast<IOSResourceUsage>(1u<<31u);
    expect(plan,IOSFramePlanError::UnknownUsage,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].usage = static_cast<IOSResourceUsage>(
        static_cast<uint32_t>(plan.resources[0].usage)|(1u<<31u));
    expect(plan,IOSFramePlanError::UnknownUsage,0u,1u);
  }

  {
    auto plan = validPlan();
    plan.resources[0].layout = {};
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.format = IOSPixelFormat::Undefined;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.extent.width = 0u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.extent.height = 0u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.mipLevels = 0u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.mipLevels = 8u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.byteSize = 1u;
    expect(plan,IOSFramePlanError::InvalidTextureLayout,0u,1u);
  }

  {
    const uint32_t invalidSamples[] = {0u,3u,16u};
    for(const uint32_t sampleCount:invalidSamples) {
      auto plan = validPlan();
      plan.resources[0].layout.sampleCount = sampleCount;
      expect(plan,IOSFramePlanError::InvalidMultisample,0u,1u);
      }
  }
  {
    auto plan = usagePlan(IOSPassKind::Render,
                          IOSUseSemantic::RenderAttachment,
                          IOSResourceUsage::RenderAttachment);
    plan.resources[2].layout.sampleCount = 2u;
    plan.resources[2].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::InvalidMultisample,0u,3u);
  }
  {
    auto plan = usagePlan(IOSPassKind::Render,
                          IOSUseSemantic::RenderAttachment,
                          IOSResourceUsage::ShaderRead);
    plan.resources[2].layout.sampleCount = 2u;
    expect(plan,IOSFramePlanError::InvalidMultisample,0u,3u);
  }
  {
    auto plan = usagePlan(
        IOSPassKind::Render,IOSUseSemantic::RenderAttachment,
        IOSResourceUsage::RenderAttachment|IOSResourceUsage::Present);
    plan.resources[2].layout.sampleCount = 2u;
    expect(plan,IOSFramePlanError::InvalidMultisample,0u,3u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,1u);
  }

  {
    const IOSPixelFormat compressed[] = {
      IOSPixelFormat::Bc1Rgba,
      IOSPixelFormat::Bc2Rgba,
      IOSPixelFormat::Bc3Rgba,
      };
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::RenderAttachment,
      IOSResourceUsage::ShaderWrite,
      IOSResourceUsage::Present,
      };
    for(const auto format:compressed) {
      for(const auto bit:forbidden) {
        auto plan = textureReadPlan(
            format,IOSResourceUsage::ShaderRead|bit);
        expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,3u);
        }
      auto plan = textureReadPlan(format,IOSResourceUsage::ShaderRead);
      plan.resources[2].layout.sampleCount = 2u;
      expect(plan,IOSFramePlanError::InvalidMultisample,0u,3u);
      }
  }

  {
    const IOSPixelFormat depths[] = {
      IOSPixelFormat::Depth16Unorm,
      IOSPixelFormat::Depth32Float,
      };
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::ShaderWrite,
      IOSResourceUsage::Present,
      };
    for(const auto format:depths) {
      for(const auto bit:forbidden) {
        auto plan = usagePlan(
            IOSPassKind::Render,IOSUseSemantic::RenderAttachment,
            IOSResourceUsage::RenderAttachment|bit);
        plan.resources[2].layout.format = format;
        expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,3u);
        }
      }
  }

  {
    auto plan = validPlan();
    plan.resources[1].usage = IOSResourceUsage::RenderAttachment |
                              IOSResourceUsage::ShaderRead;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].layout.mipLevels = 2u;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }

  {
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::AccelerationStructureBuildInput,
      IOSResourceUsage::AccelerationStructureBuildOutput,
      };
    for(const auto bit:forbidden) {
      auto plan = validPlan();
      plan.resources[0].usage = plan.resources[0].usage|bit;
      expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,1u);
      }
  }

  {
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::RenderAttachment,
      IOSResourceUsage::Present,
      IOSResourceUsage::AccelerationStructureBuildOutput,
      };
    for(const auto bit:forbidden) {
      auto plan = usagePlan(IOSPassKind::External,IOSUseSemantic::Read,
                            IOSResourceUsage::ExternalRead|bit);
      expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,3u);
      }
  }

  {
    const IOSResourceUsage forbidden[] = {
      IOSResourceUsage::ShaderWrite,
      IOSResourceUsage::RenderAttachment,
      IOSResourceUsage::BlitSource,
      IOSResourceUsage::BlitDestination,
      IOSResourceUsage::Present,
      };
    for(const auto bit:forbidden) {
      auto plan = usagePlan(
          IOSPassKind::AccelerationStructureBuild,
          IOSUseSemantic::AccelerationStructureBuildOutput,
          IOSResourceUsage::AccelerationStructureBuildOutput|bit);
      expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,3u);
      }
  }

  {
    auto plan = validPlan();
    plan.resources[0].layout.sampleCount = 2u;
    expect(plan,IOSFramePlanError::InvalidMultisample,0u,1u);
  }

  {
    auto plan = validPlan();
    plan.resources[0].lifetime = IOSResourceLifetime::Persistent;
    expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].lifetime = IOSResourceLifetime::Transient;
    expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,1u);
  }

  {
    auto base = usagePlan(IOSPassKind::External,IOSUseSemantic::Read,
                          IOSResourceUsage::ExternalRead);
    auto plan = base;
    plan.resources[2].layout.format = IOSPixelFormat::R8Unorm;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.extent.width = 1u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.extent.height = 1u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.mipLevels = 1u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.sampleCount = 1u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.byteSize = 0u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,3u);
  }

  {
    auto base = usagePlan(
        IOSPassKind::AccelerationStructureBuild,
        IOSUseSemantic::AccelerationStructureBuildOutput,
        IOSResourceUsage::AccelerationStructureBuildOutput);
    auto plan = base;
    plan.resources[2].layout.format = IOSPixelFormat::R8Unorm;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.extent.width = 1u;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.extent.height = 1u;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.mipLevels = 1u;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.sampleCount = 1u;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
    plan = base;
    plan.resources[2].layout.byteSize = 1u;
    expect(plan,IOSFramePlanError::InvalidAccelerationStructureLayout,0u,3u);
  }

  {
    auto plan = validPlan();
    plan.resources[0].id = IOSResourceId{0u};
    expect(plan,IOSFramePlanError::ResourceIdZero,0u,0u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].id = IOSResourceId{1u};
    expect(plan,IOSFramePlanError::DuplicateResourceId,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].id = IOSResourceId{2u};
    plan.resources[1].id = IOSResourceId{1u};
    expect(plan,IOSFramePlanError::ResourceIdsNotIncreasing,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].kind = static_cast<IOSResourceKind>(255u);
    expect(plan,IOSFramePlanError::UnknownResourceKind,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].lifetime = static_cast<IOSResourceLifetime>(255u);
    expect(plan,IOSFramePlanError::UnknownResourceLifetime,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].initialContent = static_cast<IOSInitialContent>(255u);
    expect(plan,IOSFramePlanError::UnknownInitialContent,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].initialContent = IOSInitialContent::Defined;
    expect(plan,IOSFramePlanError::InvalidInitialContentForLifetime,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].lifetime = IOSResourceLifetime::PerFrame;
    plan.resources[1].initialContent = IOSInitialContent::Defined;
    expect(plan,IOSFramePlanError::InvalidInitialContentForLifetime,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].aliasable = true;
    expect(plan,IOSFramePlanError::InvalidAliasableResource,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].lifetime = IOSResourceLifetime::Persistent;
    plan.resources[0].aliasable = true;
    expect(plan,IOSFramePlanError::InvalidAliasableResource,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].lifetime = IOSResourceLifetime::PerFrame;
    plan.resources[0].aliasable = true;
    expect(plan,IOSFramePlanError::InvalidAliasableResource,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].kind = IOSResourceKind::Buffer;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].aliasable = true;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].lifetime = IOSResourceLifetime::PerFrame;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].lifetime = IOSResourceLifetime::Persistent;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }
  {
    auto plan = validPlan();
    plan.resources[1].lifetime = IOSResourceLifetime::External;
    expect(plan,IOSFramePlanError::InvalidMemorylessResource,0u,2u);
  }

  {
    auto plan = validPlan();
    plan.passes[0].id = IOSPassId{0u};
    expect(plan,IOSFramePlanError::PassIdZero,0u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].id = IOSPassId{1u};
    expect(plan,IOSFramePlanError::DuplicatePassId,1u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].id = IOSPassId{2u};
    plan.passes[1].id = IOSPassId{1u};
    expect(plan,IOSFramePlanError::PassIdsNotIncreasing,1u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].kind = static_cast<IOSPassKind>(255u);
    expect(plan,IOSFramePlanError::UnknownPassKind,1u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses.clear();
    expect(plan,IOSFramePlanError::EmptyPass,2u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].resource = IOSResourceId{0u};
    expect(plan,IOSFramePlanError::UseResourceIdZero,1u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1].resource = IOSResourceId{1u};
    expect(plan,IOSFramePlanError::DuplicateUse,1u,1u);
  }
  {
    auto plan = validPlan();
    std::swap(plan.passes[0].uses[0],plan.passes[0].uses[1]);
    expect(plan,IOSFramePlanError::UsesNotIncreasing,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].resource = IOSResourceId{99u};
    expect(plan,IOSFramePlanError::UnknownResource,2u,99u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].semantic = static_cast<IOSUseSemantic>(255u);
    expect(plan,IOSFramePlanError::UnknownUseSemantic,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].semantic = static_cast<IOSUseSemantic>(255u);
    plan.passes[1].uses[0].load = static_cast<IOSLoadAction>(255u);
    plan.passes[1].uses[0].store = static_cast<IOSStoreAction>(255u);
    plan.passes[1].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownUseSemantic,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].load = static_cast<IOSLoadAction>(255u);
    expect(plan,IOSFramePlanError::UnknownLoadAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].load = static_cast<IOSLoadAction>(255u);
    plan.passes[1].uses[0].store = static_cast<IOSStoreAction>(255u);
    plan.passes[1].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownLoadAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].store = static_cast<IOSStoreAction>(255u);
    expect(plan,IOSFramePlanError::UnknownStoreAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].store = static_cast<IOSStoreAction>(255u);
    plan.passes[1].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownStoreAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownAttachmentWriteMode,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].kind = IOSPassKind::Compute;
    expect(plan,IOSFramePlanError::IncompatiblePassUse,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].kind = IOSPassKind::Render;
    plan.passes[1].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::IncompatiblePassUse,2u,1u);
  }
  {
    const IOSPassKind kinds[] = {
      IOSPassKind::Compute,
      IOSPassKind::Blit,
      IOSPassKind::External,
      };
    for(const auto kind:kinds) {
      auto plan = validPlan();
      plan.passes[1].kind = kind;
      plan.passes[1].uses[0].semantic = IOSUseSemantic::PresentSource;
      expect(plan,IOSFramePlanError::IncompatiblePassUse,2u,1u);
      }
  }
  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Texture,IOSResourceLifetime::External,
                 IOSInitialContent::Defined));
    plan.resources[0].kind = IOSResourceKind::Buffer;
    plan.resources[0].layout = {};
    plan.resources[0].layout.byteSize = 4096u;
    plan.resources[0].usage = IOSResourceUsage::ShaderRead;
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    plan.passes[2].uses[0].resource = IOSResourceId{3u};
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,1u,1u);
  }
  {
    auto plan = usagePlan(IOSPassKind::Render,
                          IOSUseSemantic::RenderAttachment,
                          IOSResourceUsage::RenderAttachment);
    plan.resources[2].layout.mipLevels = 2u;
    plan.passes[2].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,3u,3u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].load = IOSLoadAction::Load;
    expect(plan,IOSFramePlanError::InvalidLoadStore,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].store = IOSStoreAction::Store;
    expect(plan,IOSFramePlanError::InvalidLoadStore,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].load = IOSLoadAction::NotApplicable;
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidLoadStore,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].store = IOSStoreAction::NotApplicable;
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidLoadStore,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,1u);
  }
  {
    const IOSAttachmentWriteMode invalidForRead[] = {
      IOSAttachmentWriteMode::MayPreserve,
      IOSAttachmentWriteMode::FullOverwrite,
      };
    for(const auto writeMode:invalidForRead) {
      auto plan = validPlan();
      plan.passes[1].uses[0].attachmentWriteMode = writeMode;
      expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,2u,1u);
      }
  }
  {
    auto plan = usagePlan(IOSPassKind::Render,
                          IOSUseSemantic::RenderAttachment,
                          IOSResourceUsage::ShaderRead);
    plan.passes[2].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,3u,3u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].load = IOSLoadAction::Load;
    expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].load = IOSLoadAction::Load;
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,1u);
  }
  {
    auto plan = validPlan();
    for(auto& existing:plan.passes)
      ++existing.id.value;
    plan.passes.insert(plan.passes.begin(),pass(1u,IOSPassKind::External,{
      use(1u,IOSUseSemantic::ReadWrite),
      }));
    expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,1u);
  }
  {
    auto plan = validPlan();
    for(auto& existing:plan.passes)
      ++existing.id.value;
    plan.passes.insert(plan.passes.begin(),pass(1u,IOSPassKind::External,{
      use(1u,IOSUseSemantic::Read),
      }));
    expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].store = IOSStoreAction::Discard;
    expect(plan,IOSFramePlanError::ReadAfterDiscard,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].store = IOSStoreAction::Discard;
    plan.passes[1].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Persistent,
                 IOSInitialContent::Defined));
    expect(plan,IOSFramePlanError::UnusedResource,0u,3u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses.erase(plan.passes[0].uses.begin()+1);
    expect(plan,IOSFramePlanError::UnusedResource,0u,2u);
  }
  {
    const IOSLoadAction loads[] = {
      IOSLoadAction::Discard,
      IOSLoadAction::Clear,
      };
    const IOSAttachmentWriteMode writeModes[] = {
      IOSAttachmentWriteMode::MayPreserve,
      IOSAttachmentWriteMode::FullOverwrite,
      };
    for(const auto load:loads) {
      for(const auto writeMode:writeModes) {
        auto plan = validPlan();
        plan.passes[0].uses[1].load = load;
        plan.passes[0].uses[1].attachmentWriteMode = writeMode;
        expect(plan,IOSFramePlanError::None,0u,0u);
        }
      }
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1].store = IOSStoreAction::Store;
    expect(plan,IOSFramePlanError::InvalidMemorylessUse,1u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1].store = IOSStoreAction::Store;
    plan.passes[0].uses[1].attachmentWriteMode =
        IOSAttachmentWriteMode::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1] = use(2u,IOSUseSemantic::FullOverwrite);
    expect(plan,IOSFramePlanError::IncompatiblePassUse,1u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses.erase(plan.passes[0].uses.begin());
    plan.passes[0].kind = IOSPassKind::AccelerationStructureBuild;
    plan.passes[0].uses[0] = use(
        2u,IOSUseSemantic::AccelerationStructureBuildOutput);
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,1u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses.push_back(use(2u,IOSUseSemantic::Read));
    expect(plan,IOSFramePlanError::InvalidMemorylessUse,2u,2u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1] = use(2u,IOSUseSemantic::Read);
    expect(plan,IOSFramePlanError::InvalidMemorylessUse,1u,2u);
  }

  {
    auto plan = validPlan();
    plan.passes[2].kind = IOSPassKind::Blit;
    expect(plan,IOSFramePlanError::MissingPresent,0u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[2].kind = IOSPassKind::Blit;
    plan.passes[1].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::MissingPresent,0u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[2].kind = IOSPassKind::Blit;
    plan.passes[1].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownAttachmentWriteMode,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes.push_back(pass(4u,IOSPassKind::Present,{
      use(1u,IOSUseSemantic::PresentSource),
      }));
    expect(plan,IOSFramePlanError::MultiplePresent,4u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    plan.passes.push_back(pass(4u,IOSPassKind::Present,{
      use(1u,IOSUseSemantic::PresentSource),
      }));
    expect(plan,IOSFramePlanError::MultiplePresent,4u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes.push_back(pass(4u,IOSPassKind::External,{
      use(1u,IOSUseSemantic::Read),
      }));
    expect(plan,IOSFramePlanError::PresentNotLast,3u,0u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    plan.passes.push_back(pass(4u,IOSPassKind::External,{
      use(1u,IOSUseSemantic::Read),
      }));
    expect(plan,IOSFramePlanError::PresentNotLast,3u,0u);
  }
  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Texture,IOSResourceLifetime::External,
                 IOSInitialContent::Defined));
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    plan.passes[2].uses.push_back(use(3u,IOSUseSemantic::PresentSource));
    expect(plan,IOSFramePlanError::InvalidPresentUse,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[2].uses[0].semantic = IOSUseSemantic::Read;
    expect(plan,IOSFramePlanError::InvalidPresentUse,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[2].uses[0].semantic = IOSUseSemantic::Read;
    plan.passes[2].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidPresentUse,3u,1u);
  }
  {
    const IOSAttachmentWriteMode invalidForPresent[] = {
      IOSAttachmentWriteMode::MayPreserve,
      IOSAttachmentWriteMode::FullOverwrite,
      };
    for(const auto writeMode:invalidForPresent) {
      auto plan = validPlan();
      plan.passes[2].uses[0].attachmentWriteMode = writeMode;
      expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,3u,1u);
      }
  }
  {
    auto plan = validPlan();
    plan.passes[2].uses[0].attachmentWriteMode =
        static_cast<IOSAttachmentWriteMode>(255u);
    expect(plan,IOSFramePlanError::UnknownAttachmentWriteMode,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].lifetime = IOSResourceLifetime::Persistent;
    expect(plan,IOSFramePlanError::IncompatibleFormatUsage,0u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].kind = IOSResourceKind::Buffer;
    plan.resources[0].layout = {};
    plan.resources[0].layout.byteSize = 4096u;
    plan.resources[0].usage = IOSResourceUsage::ShaderRead;
    expect(plan,IOSFramePlanError::InvalidPresentResource,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].kind = IOSResourceKind::Buffer;
    plan.resources[0].layout = {};
    plan.resources[0].layout.byteSize = 4096u;
    plan.resources[0].usage = IOSResourceUsage::ShaderRead;
    plan.passes[2].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidPresentResource,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined));
    plan.passes[0].uses[0].store = IOSStoreAction::Discard;
    plan.passes[1].uses[0] = use(3u,IOSUseSemantic::FullOverwrite);
    expect(plan,IOSFramePlanError::PresentUndefined,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined));
    plan.passes[0].uses[0].store = IOSStoreAction::Discard;
    plan.passes[1].uses[0] = use(3u,IOSUseSemantic::FullOverwrite);
    plan.passes[2].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,3u,1u);
  }

  {
    auto plan = validPlan();
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Transient,
                 IOSInitialContent::Undefined));
    plan.passes[1] = pass(2u,IOSPassKind::AccelerationStructureBuild,{
      use(3u,IOSUseSemantic::AccelerationStructureBuildOutput),
      });
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,2u,3u);
  }

  {
    auto plan = aliasRangePlan({{1u},{1u}},0u);
    expect(plan,IOSFramePlanError::None,0u,0u);
    plan.resources[1].aliasable = false;
    plan.resources[2].aliasable = false;
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    const auto plan = aliasRangePlan({{1u},{2u}},7u);
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    const auto plan = aliasRangePlan({{2u},{1u}},7u);
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    const auto plan = aliasRangePlan({{1u},{2u},{3u}},7u);
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    const auto plan = aliasRangePlan(
        {{1u},{2u},{3u},{4u},{5u},{6u}},
        {31u,2u,std::numeric_limits<uint32_t>::max(),31u,
         std::numeric_limits<uint32_t>::max(),2u});
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    const auto plan = aliasRangePlan(
        {{1u},{2u},{1u},{2u}},
        {5u,5u,7u,7u});
    expect(plan,IOSFramePlanError::None,0u,0u);
  }
  {
    IOSFramePlan plan;
    plan.resources = {
      resource(1u,IOSResourceKind::Texture,IOSResourceLifetime::External,
               IOSInitialContent::Defined),
      resource(2u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
               IOSInitialContent::Undefined,false,true,91u),
      resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Transient,
               IOSInitialContent::Undefined,false,true,91u),
      resource(4u,IOSResourceKind::AccelerationStructure,
               IOSResourceLifetime::Transient,IOSInitialContent::Undefined,
               false,true,91u),
      resource(5u,IOSResourceKind::Texture,IOSResourceLifetime::Transient,
               IOSInitialContent::Undefined,false,true,91u),
      };
    plan.resources[1].layout = {
      IOSPixelFormat::R16Float,{13u,7u},1u,1u,0u};
    plan.resources[1].usage = IOSResourceUsage::RenderAttachment;
    plan.resources[2].layout.byteSize =
        std::numeric_limits<uint64_t>::max();
    plan.resources[2].usage = IOSResourceUsage::BlitDestination;
    plan.resources[3].usage =
        IOSResourceUsage::AccelerationStructureBuildOutput;
    plan.resources[4].layout = {
      IOSPixelFormat::Rgba16Float,{3u,5u},1u,1u,0u};
    plan.resources[4].usage = IOSResourceUsage::ShaderWrite;
    plan.passes = {
      pass(1u,IOSPassKind::Render,{
        use(2u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Clear,IOSStoreAction::Store,
            IOSAttachmentWriteMode::MayPreserve),
        }),
      pass(2u,IOSPassKind::Blit,{
        use(3u,IOSUseSemantic::FullOverwrite),
        }),
      pass(3u,IOSPassKind::AccelerationStructureBuild,{
        use(4u,IOSUseSemantic::AccelerationStructureBuildOutput),
        }),
      pass(4u,IOSPassKind::Compute,{
        use(5u,IOSUseSemantic::FullOverwrite),
        }),
      pass(5u,IOSPassKind::Present,{
        use(1u,IOSUseSemantic::PresentSource),
        }),
      };
    expect(plan,IOSFramePlanError::None,0u,0u);
  }

  {
    auto plan = aliasRangePlan({{1u},{2u}},9u);
    plan.resources[2].aliasable = false;
    expect(plan,IOSFramePlanError::InvalidAliasGroupMember,0u,3u);
  }
  {
    auto plan = aliasRangePlan({{1u},{2u}},9u);
    plan.resources[2].aliasable = false;
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,2u);
  }
  {
    const auto plan = aliasRangePlan({{1u}},9u);
    expect(plan,IOSFramePlanError::SingletonAliasGroup,0u,2u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,2u);
  }
  {
    const auto plan = aliasRangePlan({{1u},{1u}},9u);
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,1u,3u);
  }
  {
    auto plan = aliasRangePlan({{1u},{1u}},9u);
    plan.passes[0].uses[0].attachmentWriteMode =
        IOSAttachmentWriteMode::MayPreserve;
    expect(plan,IOSFramePlanError::InvalidAttachmentWriteMode,1u,2u);
  }
  {
    const auto plan = aliasRangePlan({{1u,2u},{2u,3u}},9u);
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,2u,3u);
  }
  {
    const auto plan = aliasRangePlan({{3u,4u},{1u,5u}},9u);
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,3u,3u);
  }
  {
    const auto plan = aliasRangePlan({{1u,3u},{2u}},9u);
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,2u,3u);
  }
  {
    const auto plan = aliasRangePlan({{1u,3u},{4u},{2u}},9u);
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,2u,4u);
  }
  {
    const auto plan = aliasRangePlan(
        {{3u,4u},{1u,2u},{2u,3u},{2u,4u}},
        {9u,1u,9u,1u});
    expect(plan,IOSFramePlanError::OverlappingAliasGroupUse,3u,4u);
  }

  {
    auto plan = aliasRangePlan({{1u},{2u},{3u}},{5u,7u,7u});
    plan.resources[2].aliasable = false;
    expect(plan,IOSFramePlanError::InvalidAliasGroupMember,0u,3u);
  }
  {
    const auto plan = aliasRangePlan({{1u},{2u},{2u}},{5u,7u,7u});
    expect(plan,IOSFramePlanError::SingletonAliasGroup,0u,2u);
  }

  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources[0].id = IOSResourceId{};
    expect(plan,IOSFramePlanError::ResourceIdZero,0u,0u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources[1].lifetime = IOSResourceLifetime::Persistent;
    expect(plan,IOSFramePlanError::InvalidAliasableResource,0u,2u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.passes.back().kind = IOSPassKind::Blit;
    expect(plan,IOSFramePlanError::MissingPresent,0u,0u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Persistent,
                 IOSInitialContent::Defined));
    expect(plan,IOSFramePlanError::UnusedResource,0u,3u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.passes[0].uses[0].semantic = IOSUseSemantic::Read;
    expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,2u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources[0].initialContent = IOSInitialContent::Undefined;
    expect(plan,IOSFramePlanError::PresentUndefined,2u,1u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources[1].layout.byteSize = 0u;
    expect(plan,IOSFramePlanError::InvalidBufferLayout,0u,2u);
  }
  {
    auto plan = aliasRangePlan({{1u}},9u);
    plan.resources[1].usage = IOSResourceUsage::ShaderRead;
    expect(plan,IOSFramePlanError::MissingDeclaredUsage,1u,2u);
  }
  }
