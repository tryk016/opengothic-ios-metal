#include "graphics/iosframeplan.h"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <utility>

namespace {

IOSResourceDesc resource(
    uint32_t id,
    IOSResourceKind kind,
    IOSResourceLifetime lifetime,
    IOSInitialContent initial,
    bool memoryless = false,
    bool aliasable = false) {
  return {IOSResourceId{id},kind,lifetime,initial,memoryless,aliasable};
  }

IOSResourceUse use(
    uint32_t id,
    IOSUseSemantic semantic,
    IOSLoadAction load = IOSLoadAction::NotApplicable,
    IOSStoreAction store = IOSStoreAction::NotApplicable) {
  return {IOSResourceId{id},semantic,load,store};
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
          IOSLoadAction::Clear,IOSStoreAction::Store),
      use(2u,IOSUseSemantic::RenderAttachment,
          IOSLoadAction::Discard,IOSStoreAction::Discard),
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
  const auto result = plan.validate();
  if(result.error!=error || result.pass.value!=passId ||
     result.resource.value!=resourceId)
    std::fprintf(stderr,"expected %u/%u/%u, got %u/%u/%u\n",
                 static_cast<unsigned>(error),passId,resourceId,
                 static_cast<unsigned>(result.error),result.pass.value,
                 result.resource.value);
  assert(result.error==error);
  assert(result.pass.value==passId);
  assert(result.resource.value==resourceId);
  }

}

int main() {
  static_assert(IOSFramePlanABIVersion==1u);
  static_assert(sizeof(IOSResourceId)==sizeof(uint32_t));
  static_assert(sizeof(IOSPassId)==sizeof(uint32_t));
  static_assert(IOSResourceId{7u}==IOSResourceId{7u});
  static_assert(IOSPassId{9u}==IOSPassId{9u});
  static_assert(bool(IOSResourceId{1u}));
  static_assert(!bool(IOSResourceId{}));
  static_assert(bool(IOSPassId{1u}));
  static_assert(!bool(IOSPassId{}));
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
#undef IOS_ASSERT_ORDINAL

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
            IOSLoadAction::Clear,IOSStoreAction::Discard));
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
            IOSLoadAction::Discard,IOSStoreAction::Store));
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    expect(plan,IOSFramePlanError::None,0u,0u);
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
            IOSLoadAction::Clear,IOSStoreAction::Store),
        use(2u,IOSUseSemantic::RenderAttachment,
            IOSLoadAction::Discard,IOSStoreAction::Discard),
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
    plan.passes[1].uses[0].load = static_cast<IOSLoadAction>(255u);
    expect(plan,IOSFramePlanError::UnknownLoadAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[1].uses[0].store = static_cast<IOSStoreAction>(255u);
    expect(plan,IOSFramePlanError::UnknownStoreAction,2u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].kind = IOSPassKind::Compute;
    expect(plan,IOSFramePlanError::IncompatiblePassUse,1u,1u);
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
    plan.passes[1].uses.push_back(use(3u,IOSUseSemantic::Read));
    plan.passes[2].uses[0].resource = IOSResourceId{3u};
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,1u,1u);
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
    expect(plan,IOSFramePlanError::InvalidLoadStore,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].store = IOSStoreAction::NotApplicable;
    expect(plan,IOSFramePlanError::InvalidLoadStore,1u,1u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[0].load = IOSLoadAction::Load;
    expect(plan,IOSFramePlanError::ReadBeforeWrite,1u,1u);
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
    plan.resources.push_back(
        resource(3u,IOSResourceKind::Buffer,IOSResourceLifetime::Persistent,
                 IOSInitialContent::Defined));
    expect(plan,IOSFramePlanError::UnusedResource,0u,3u);
  }
  {
    auto plan = validPlan();
    plan.passes[0].uses[1].store = IOSStoreAction::Store;
    expect(plan,IOSFramePlanError::InvalidMemorylessUse,1u,2u);
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
    plan.resources[0].lifetime = IOSResourceLifetime::Persistent;
    expect(plan,IOSFramePlanError::InvalidPresentResource,3u,1u);
  }
  {
    auto plan = validPlan();
    plan.resources[0].kind = IOSResourceKind::Buffer;
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
    plan.passes[1] = pass(2u,IOSPassKind::AccelerationStructureBuild,{
      use(3u,IOSUseSemantic::AccelerationStructureBuildOutput),
      });
    expect(plan,IOSFramePlanError::IncompatibleResourceUse,2u,3u);
  }
  }
