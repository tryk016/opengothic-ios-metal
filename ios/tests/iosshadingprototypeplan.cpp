#include "graphics/iosshadingprototypeplan.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <utility>

namespace {

enum class CommonField : uint8_t {
  OpaqueGeometryInputs,
  AlphaTestGeometryInputs,
  LightInputs,
  PresentFormat,
  OutputFormat,
  OutputWidth,
  OutputHeight,
  OutputMipLevels,
  OutputSampleCount,
  };

enum class RuntimeField : uint8_t {
  BorrowedExistingDevice,
  BorrowedExistingQueue,
  BorrowedVirginCommandBuffer,
  ContextOwnsFence,
  CreatesDevice,
  CreatesQueue,
  CreatesCommandBuffer,
  Commits,
  Waits,
  DrawableAcquisitions,
  Presents,
  };

enum class TopologyField : uint8_t {
  CommandBuffers,
  Submits,
  RenderEncoders,
  Draws,
  TileDispatches,
  ComputeEncoders,
  DrawableAcquisitions,
  Presents,
  OperationCount,
  Operation0,
  Operation1,
  Operation2,
  };

enum class ResourceField : uint8_t {
  Id,
  Kind,
  Lifetime,
  InitialContent,
  Memoryless,
  Aliasable,
  AliasGroup,
  Format,
  Width,
  Height,
  MipLevels,
  SampleCount,
  ByteSize,
  Usage,
  };

enum class PassField : uint8_t {
  Id,
  Kind,
  };

enum class UseField : uint8_t {
  Resource,
  Semantic,
  Load,
  Store,
  AttachmentWriteMode,
  };

constexpr std::array Kinds = {
  IOSShadingPrototypeKind::TileDeferred,
  IOSShadingPrototypeKind::ForwardPlus,
  };

constexpr std::array CommonFields = {
  CommonField::OpaqueGeometryInputs,
  CommonField::AlphaTestGeometryInputs,
  CommonField::LightInputs,
  CommonField::PresentFormat,
  CommonField::OutputFormat,
  CommonField::OutputWidth,
  CommonField::OutputHeight,
  CommonField::OutputMipLevels,
  CommonField::OutputSampleCount,
  };

constexpr std::array TopologyFields = {
  TopologyField::CommandBuffers,
  TopologyField::Submits,
  TopologyField::RenderEncoders,
  TopologyField::Draws,
  TopologyField::TileDispatches,
  TopologyField::ComputeEncoders,
  TopologyField::DrawableAcquisitions,
  TopologyField::Presents,
  TopologyField::OperationCount,
  TopologyField::Operation0,
  TopologyField::Operation1,
  TopologyField::Operation2,
  };

constexpr std::array RuntimeFields = {
  RuntimeField::BorrowedExistingDevice,
  RuntimeField::BorrowedExistingQueue,
  RuntimeField::BorrowedVirginCommandBuffer,
  RuntimeField::ContextOwnsFence,
  RuntimeField::CreatesDevice,
  RuntimeField::CreatesQueue,
  RuntimeField::CreatesCommandBuffer,
  RuntimeField::Commits,
  RuntimeField::Waits,
  RuntimeField::DrawableAcquisitions,
  RuntimeField::Presents,
  };

constexpr std::array ResourceFields = {
  ResourceField::Id,
  ResourceField::Kind,
  ResourceField::Lifetime,
  ResourceField::InitialContent,
  ResourceField::Memoryless,
  ResourceField::Aliasable,
  ResourceField::AliasGroup,
  ResourceField::Format,
  ResourceField::Width,
  ResourceField::Height,
  ResourceField::MipLevels,
  ResourceField::SampleCount,
  ResourceField::ByteSize,
  ResourceField::Usage,
  };

constexpr std::array PassFields = {
  PassField::Id,
  PassField::Kind,
  };

constexpr std::array UseFields = {
  UseField::Resource,
  UseField::Semantic,
  UseField::Load,
  UseField::Store,
  UseField::AttachmentWriteMode,
  };

template<class Mutation>
bool rejects(IOSShadingPrototypeKind kind,
             Mutation&& mutation) {
  IOSShadingPrototypePlan plan = iosShadingPrototypePlan(kind);
  std::forward<Mutation>(mutation)(plan);
  return !plan.validate() && !iosShadingPrototypeSelectPlan(plan);
  }

void mutate(IOSShadingPrototypeCommonContract& common,
            CommonField field) noexcept {
  switch(field) {
    case CommonField::OpaqueGeometryInputs:
      common.opaqueGeometryInputs = 2u;
      return;
    case CommonField::AlphaTestGeometryInputs:
      common.alphaTestGeometryInputs = 2u;
      return;
    case CommonField::LightInputs:
      common.lightInputs = 2u;
      return;
    case CommonField::PresentFormat:
      common.presentFormat = IOSPixelFormat::Rgba8Unorm;
      return;
    case CommonField::OutputFormat:
      common.outputFormat = IOSPixelFormat::Rgba16Float;
      return;
    case CommonField::OutputWidth:
      common.outputExtent.width = 8u;
      return;
    case CommonField::OutputHeight:
      common.outputExtent.height = 8u;
      return;
    case CommonField::OutputMipLevels:
      common.outputMipLevels = 2u;
      return;
    case CommonField::OutputSampleCount:
      common.outputSampleCount = 2u;
      return;
    }
  }

void mutate(IOSShadingPrototypeTopology& topology,
            TopologyField field) noexcept {
  switch(field) {
    case TopologyField::CommandBuffers:
      topology.commandBuffers = 2u;
      return;
    case TopologyField::Submits:
      topology.submits = 2u;
      return;
    case TopologyField::RenderEncoders:
      topology.renderEncoders = 2u;
      return;
    case TopologyField::Draws:
      topology.draws = 3u;
      return;
    case TopologyField::TileDispatches:
      topology.tileDispatches =
          topology.tileDispatches==0u ? 1u : 0u;
      return;
    case TopologyField::ComputeEncoders:
      topology.computeEncoders =
          topology.computeEncoders==0u ? 1u : 0u;
      return;
    case TopologyField::DrawableAcquisitions:
      topology.drawableAcquisitions = 1u;
      return;
    case TopologyField::Presents:
      topology.presents = 1u;
      return;
    case TopologyField::OperationCount:
      topology.operationCount = 2u;
      return;
    case TopologyField::Operation0:
      topology.operations[0] =
          topology.operations[0]==
            IOSShadingPrototypeOperation::BuildLightList
              ? IOSShadingPrototypeOperation::DispatchTileLighting
              : IOSShadingPrototypeOperation::BuildLightList;
      return;
    case TopologyField::Operation1:
      topology.operations[1] =
          topology.operations[1]==
            IOSShadingPrototypeOperation::DrawOpaque
              ? IOSShadingPrototypeOperation::DispatchTileLighting
              : IOSShadingPrototypeOperation::DrawOpaque;
      return;
    case TopologyField::Operation2:
      topology.operations[2] =
          topology.operations[2]==
            IOSShadingPrototypeOperation::DrawAlphaTest
              ? IOSShadingPrototypeOperation::BuildLightList
              : IOSShadingPrototypeOperation::DrawAlphaTest;
      return;
    }
  }

void mutate(IOSShadingPrototypeRuntimeContract& runtime,
            RuntimeField field) noexcept {
  switch(field) {
    case RuntimeField::BorrowedExistingDevice:
      runtime.borrowedExistingDevice = 0u;
      return;
    case RuntimeField::BorrowedExistingQueue:
      runtime.borrowedExistingQueue = 0u;
      return;
    case RuntimeField::BorrowedVirginCommandBuffer:
      runtime.borrowedVirginCommandBuffer = 0u;
      return;
    case RuntimeField::ContextOwnsFence:
      runtime.contextOwnsFence = 0u;
      return;
    case RuntimeField::CreatesDevice:
      runtime.createsDevice = 1u;
      return;
    case RuntimeField::CreatesQueue:
      runtime.createsQueue = 1u;
      return;
    case RuntimeField::CreatesCommandBuffer:
      runtime.createsCommandBuffer = 1u;
      return;
    case RuntimeField::Commits:
      runtime.commits = 1u;
      return;
    case RuntimeField::Waits:
      runtime.waits = 1u;
      return;
    case RuntimeField::DrawableAcquisitions:
      runtime.drawableAcquisitions = 1u;
      return;
    case RuntimeField::Presents:
      runtime.presents = 1u;
      return;
    }
  }

void mutate(IOSResourceDesc& resource,
            ResourceField field) noexcept {
  switch(field) {
    case ResourceField::Id:
      resource.id = IOSResourceId{9u};
      return;
    case ResourceField::Kind:
      resource.kind = IOSResourceKind::AccelerationStructure;
      return;
    case ResourceField::Lifetime:
      resource.lifetime = IOSResourceLifetime::Persistent;
      return;
    case ResourceField::InitialContent:
      resource.initialContent =
          resource.initialContent==IOSInitialContent::Defined
            ? IOSInitialContent::Undefined
            : IOSInitialContent::Defined;
      return;
    case ResourceField::Memoryless:
      resource.memoryless = !resource.memoryless;
      return;
    case ResourceField::Aliasable:
      resource.aliasable = !resource.aliasable;
      return;
    case ResourceField::AliasGroup:
      resource.aliasGroup = IOSAliasGroupId{9u};
      return;
    case ResourceField::Format:
      resource.layout.format = IOSPixelFormat::R16Float;
      return;
    case ResourceField::Width:
      resource.layout.extent.width =
          resource.layout.extent.width==0u ? 1u : 8u;
      return;
    case ResourceField::Height:
      resource.layout.extent.height =
          resource.layout.extent.height==0u ? 1u : 8u;
      return;
    case ResourceField::MipLevels:
      resource.layout.mipLevels =
          resource.layout.mipLevels==0u ? 1u : 2u;
      return;
    case ResourceField::SampleCount:
      resource.layout.sampleCount =
          resource.layout.sampleCount==0u ? 1u : 2u;
      return;
    case ResourceField::ByteSize:
      resource.layout.byteSize =
          resource.layout.byteSize==0u ? 16u : 512u;
      return;
    case ResourceField::Usage:
      resource.usage = IOSResourceUsage::ExternalRead;
      return;
    }
  }

void mutate(IOSPassDesc& pass,
            PassField field) noexcept {
  switch(field) {
    case PassField::Id:
      pass.id = IOSPassId{9u};
      return;
    case PassField::Kind:
      pass.kind = IOSPassKind::Blit;
      return;
    }
  }

void mutate(IOSResourceUse& use,
            UseField field) noexcept {
  switch(field) {
    case UseField::Resource:
      use.resource = IOSResourceId{9u};
      return;
    case UseField::Semantic:
      use.semantic = IOSUseSemantic::ReadWrite;
      return;
    case UseField::Load:
      use.load = use.load==IOSLoadAction::Load
                   ? IOSLoadAction::Discard
                   : IOSLoadAction::Load;
      return;
    case UseField::Store:
      use.store = use.store==IOSStoreAction::Store
                    ? IOSStoreAction::Discard
                    : IOSStoreAction::Store;
      return;
    case UseField::AttachmentWriteMode:
      use.attachmentWriteMode =
          use.attachmentWriteMode==IOSAttachmentWriteMode::MayPreserve
            ? IOSAttachmentWriteMode::FullOverwrite
            : IOSAttachmentWriteMode::MayPreserve;
      return;
    }
  }

bool exactResource(const IOSResourceDesc& resource,
                   IOSResourceId id,
                   IOSResourceKind kind,
                   IOSResourceLifetime lifetime,
                   IOSInitialContent initialContent,
                   bool memoryless,
                   IOSResourceLayout layout,
                   IOSResourceUsage usage) noexcept {
  return resource.id==id &&
         resource.kind==kind &&
         resource.lifetime==lifetime &&
         resource.initialContent==initialContent &&
         resource.memoryless==memoryless &&
         !resource.aliasable &&
         !resource.aliasGroup &&
         resource.layout==layout &&
         resource.usage==usage;
  }

bool exactUse(const IOSResourceUse& use,
              IOSResourceId resource,
              IOSUseSemantic semantic,
              IOSLoadAction load,
              IOSStoreAction store,
              IOSAttachmentWriteMode writeMode) noexcept {
  return use.resource==resource &&
         use.semantic==semantic &&
         use.load==load &&
         use.store==store &&
         use.attachmentWriteMode==writeMode;
  }

bool exactCommon(const IOSShadingPrototypeCommonContract& common) noexcept {
  return common.opaqueGeometryInputs==1u &&
         common.alphaTestGeometryInputs==1u &&
         common.lightInputs==1u &&
         common.presentFormat==IOSPixelFormat::Bgra8Unorm &&
         common.outputFormat==IOSPixelFormat::Rgba8Unorm &&
         common.outputExtent==IOSExtent2D{4u,4u} &&
         common.outputMipLevels==1u &&
         common.outputSampleCount==1u;
  }

bool exactRuntime(const IOSShadingPrototypeRuntimeContract& runtime) noexcept {
  return runtime.borrowedExistingDevice==1u &&
         runtime.borrowedExistingQueue==1u &&
         runtime.borrowedVirginCommandBuffer==1u &&
         runtime.contextOwnsFence==1u &&
         runtime.createsDevice==0u &&
         runtime.createsQueue==0u &&
         runtime.createsCommandBuffer==0u &&
         runtime.commits==0u &&
         runtime.waits==0u &&
         runtime.drawableAcquisitions==0u &&
         runtime.presents==0u;
  }

bool exactTopology(const IOSShadingPrototypeTopology& topology,
                   uint32_t tileDispatches,
                   uint32_t computeEncoders,
                   std::array<IOSShadingPrototypeOperation,3u>
                       operations) noexcept {
  return topology.commandBuffers==1u &&
         topology.submits==1u &&
         topology.renderEncoders==1u &&
         topology.draws==2u &&
         topology.tileDispatches==tileDispatches &&
         topology.computeEncoders==computeEncoders &&
         topology.drawableAcquisitions==0u &&
         topology.presents==0u &&
         topology.operationCount==3u &&
         topology.operations==operations;
  }

int checkTilePlan(const IOSShadingPrototypePlan& plan) {
  if(plan.kind!=IOSShadingPrototypeKind::TileDeferred ||
     !exactCommon(plan.common) ||
     !exactRuntime(plan.runtime) ||
     !exactTopology(
       plan.topology,
       1u,
       0u,
       {
         IOSShadingPrototypeOperation::DrawOpaque,
         IOSShadingPrototypeOperation::DrawAlphaTest,
         IOSShadingPrototypeOperation::DispatchTileLighting,
       }) ||
     plan.framePlan.resources.size()!=3u ||
     plan.framePlan.passes.size()!=2u)
    return 1;

  const auto& resources = plan.framePlan.resources;
  if(!exactResource(
       resources[0],
       IOSResourceId{1u},
       IOSResourceKind::Texture,
       IOSResourceLifetime::External,
       IOSInitialContent::Defined,
       false,
       {IOSPixelFormat::Bgra8Unorm,{4u,4u},1u,1u,0u},
       IOSResourceUsage::Present) ||
     !exactResource(
       resources[1],
       IOSResourceId{2u},
       IOSResourceKind::Texture,
       IOSResourceLifetime::Transient,
       IOSInitialContent::Undefined,
       false,
       {IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u},
       IOSResourceUsage::RenderAttachment) ||
     !exactResource(
       resources[2],
       IOSResourceId{3u},
       IOSResourceKind::Texture,
       IOSResourceLifetime::Transient,
       IOSInitialContent::Undefined,
       true,
       {IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u},
       IOSResourceUsage::RenderAttachment))
    return 2;

  const auto& render = plan.framePlan.passes[0];
  const auto& present = plan.framePlan.passes[1];
  if(render.id!=IOSPassId{1u} ||
     render.kind!=IOSPassKind::Render ||
     render.uses.size()!=2u ||
     !exactUse(
       render.uses[0],
       IOSResourceId{2u},
       IOSUseSemantic::RenderAttachment,
       IOSLoadAction::Clear,
       IOSStoreAction::Store,
       IOSAttachmentWriteMode::FullOverwrite) ||
     !exactUse(
       render.uses[1],
       IOSResourceId{3u},
       IOSUseSemantic::RenderAttachment,
       IOSLoadAction::Discard,
       IOSStoreAction::Discard,
       IOSAttachmentWriteMode::FullOverwrite) ||
     present.id!=IOSPassId{2u} ||
     present.kind!=IOSPassKind::Present ||
     present.uses.size()!=1u ||
     !exactUse(
       present.uses[0],
       IOSResourceId{1u},
       IOSUseSemantic::PresentSource,
       IOSLoadAction::NotApplicable,
       IOSStoreAction::NotApplicable,
       IOSAttachmentWriteMode::NotApplicable))
    return 3;
  return 0;
  }

int checkForwardPlan(const IOSShadingPrototypePlan& plan) {
  if(plan.kind!=IOSShadingPrototypeKind::ForwardPlus ||
     !exactCommon(plan.common) ||
     !exactRuntime(plan.runtime) ||
     !exactTopology(
       plan.topology,
       0u,
       1u,
       {
         IOSShadingPrototypeOperation::BuildLightList,
         IOSShadingPrototypeOperation::DrawOpaque,
         IOSShadingPrototypeOperation::DrawAlphaTest,
       }) ||
     plan.framePlan.resources.size()!=3u ||
     plan.framePlan.passes.size()!=3u)
    return 1;

  const auto& resources = plan.framePlan.resources;
  if(!exactResource(
       resources[0],
       IOSResourceId{1u},
       IOSResourceKind::Texture,
       IOSResourceLifetime::External,
       IOSInitialContent::Defined,
       false,
       {IOSPixelFormat::Bgra8Unorm,{4u,4u},1u,1u,0u},
       IOSResourceUsage::Present) ||
     !exactResource(
       resources[1],
       IOSResourceId{2u},
       IOSResourceKind::Texture,
       IOSResourceLifetime::Transient,
       IOSInitialContent::Undefined,
       false,
       {IOSPixelFormat::Rgba8Unorm,{4u,4u},1u,1u,0u},
       IOSResourceUsage::RenderAttachment) ||
     !exactResource(
       resources[2],
       IOSResourceId{3u},
       IOSResourceKind::Buffer,
       IOSResourceLifetime::Transient,
       IOSInitialContent::Undefined,
       false,
       {IOSPixelFormat::Undefined,{0u,0u},0u,0u,256u},
       IOSResourceUsage::ShaderRead|IOSResourceUsage::ShaderWrite))
    return 2;

  const auto& compute = plan.framePlan.passes[0];
  const auto& render = plan.framePlan.passes[1];
  const auto& present = plan.framePlan.passes[2];
  if(compute.id!=IOSPassId{1u} ||
     compute.kind!=IOSPassKind::Compute ||
     compute.uses.size()!=1u ||
     !exactUse(
       compute.uses[0],
       IOSResourceId{3u},
       IOSUseSemantic::FullOverwrite,
       IOSLoadAction::NotApplicable,
       IOSStoreAction::NotApplicable,
       IOSAttachmentWriteMode::NotApplicable) ||
     render.id!=IOSPassId{2u} ||
     render.kind!=IOSPassKind::Render ||
     render.uses.size()!=2u ||
     !exactUse(
       render.uses[0],
       IOSResourceId{2u},
       IOSUseSemantic::RenderAttachment,
       IOSLoadAction::Clear,
       IOSStoreAction::Store,
       IOSAttachmentWriteMode::FullOverwrite) ||
     !exactUse(
       render.uses[1],
       IOSResourceId{3u},
       IOSUseSemantic::Read,
       IOSLoadAction::NotApplicable,
       IOSStoreAction::NotApplicable,
       IOSAttachmentWriteMode::NotApplicable) ||
     present.id!=IOSPassId{3u} ||
     present.kind!=IOSPassKind::Present ||
     present.uses.size()!=1u ||
     !exactUse(
       present.uses[0],
       IOSResourceId{1u},
       IOSUseSemantic::PresentSource,
       IOSLoadAction::NotApplicable,
       IOSStoreAction::NotApplicable,
       IOSAttachmentWriteMode::NotApplicable))
    return 3;
  return 0;
  }

}

int main() {
  static_assert(IOSFramePlanABIVersion==4u);
  static_assert(IOSShadingPrototypePlanABIVersion==1u);
  static_assert(IOSShadingPrototypeNoPass==0xffffffffu);

  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeKind::TileDeferred)==0u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeKind::ForwardPlus)==1u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeOperation::BuildLightList)==0u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeOperation::DrawOpaque)==1u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeOperation::DrawAlphaTest)==2u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeOperation::DispatchTileLighting)==3u);
  static_assert(sizeof(IOSShadingPrototypeOperation)==1u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::None)==0u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::UnsupportedKind)==1u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::InvalidFramePlan)==2u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::CommonContractMismatch)==3u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::RuntimeContractMismatch)==4u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::TopologyMismatch)==5u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypePlanError::FramePlanMismatch)==6u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeSelectionStatus::Supported)==0u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeSelectionStatus::Invalid)==1u);
  static_assert(static_cast<uint8_t>(
      IOSShadingPrototypeSelectionStatus::Unsupported)==2u);

  static_assert(std::is_standard_layout_v<
      IOSShadingPrototypeCommonContract>);
  static_assert(std::is_trivially_copyable_v<
      IOSShadingPrototypeCommonContract>);
  static_assert(alignof(IOSShadingPrototypeCommonContract)==4u);
  static_assert(sizeof(IOSShadingPrototypeCommonContract)==32u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,opaqueGeometryInputs)==0u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,alphaTestGeometryInputs)==4u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,lightInputs)==8u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,presentFormat)==12u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,outputFormat)==13u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,outputExtent)==16u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,outputMipLevels)==24u);
  static_assert(offsetof(
      IOSShadingPrototypeCommonContract,outputSampleCount)==28u);

  static_assert(std::is_standard_layout_v<
      IOSShadingPrototypeRuntimeContract>);
  static_assert(std::is_trivially_copyable_v<
      IOSShadingPrototypeRuntimeContract>);
  static_assert(alignof(IOSShadingPrototypeRuntimeContract)==4u);
  static_assert(sizeof(IOSShadingPrototypeRuntimeContract)==44u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,borrowedExistingDevice)==0u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,borrowedExistingQueue)==4u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,
      borrowedVirginCommandBuffer)==8u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,contextOwnsFence)==12u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,createsDevice)==16u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,createsQueue)==20u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,createsCommandBuffer)==24u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,commits)==28u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,waits)==32u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,drawableAcquisitions)==36u);
  static_assert(offsetof(
      IOSShadingPrototypeRuntimeContract,presents)==40u);

  static_assert(std::is_standard_layout_v<
      IOSShadingPrototypeTopology>);
  static_assert(std::is_trivially_copyable_v<
      IOSShadingPrototypeTopology>);
  static_assert(alignof(IOSShadingPrototypeTopology)==4u);
  static_assert(sizeof(IOSShadingPrototypeTopology)==40u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,commandBuffers)==0u);
  static_assert(offsetof(IOSShadingPrototypeTopology,submits)==4u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,renderEncoders)==8u);
  static_assert(offsetof(IOSShadingPrototypeTopology,draws)==12u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,tileDispatches)==16u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,computeEncoders)==20u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,drawableAcquisitions)==24u);
  static_assert(offsetof(IOSShadingPrototypeTopology,presents)==28u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,operationCount)==32u);
  static_assert(offsetof(
      IOSShadingPrototypeTopology,operations)==36u);

  static_assert(std::is_standard_layout_v<
      IOSShadingPrototypePlanValidation>);
  static_assert(std::is_trivially_copyable_v<
      IOSShadingPrototypePlanValidation>);
  static_assert(alignof(IOSShadingPrototypePlanValidation)==4u);
  static_assert(sizeof(IOSShadingPrototypePlanValidation)==16u);
  static_assert(offsetof(
      IOSShadingPrototypePlanValidation,error)==0u);
  static_assert(offsetof(
      IOSShadingPrototypePlanValidation,framePlan)==4u);

  static_assert(std::is_standard_layout_v<
      IOSShadingPrototypePlanSelection>);
  static_assert(std::is_trivially_copyable_v<
      IOSShadingPrototypePlanSelection>);
  static_assert(alignof(IOSShadingPrototypePlanSelection)==4u);
  static_assert(sizeof(IOSShadingPrototypePlanSelection)==28u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,status)==0u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,kind)==1u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,presentResource)==4u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,outputResource)==8u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,workingResource)==12u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,computePass)==16u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,renderPass)==20u);
  static_assert(offsetof(
      IOSShadingPrototypePlanSelection,presentPass)==24u);

  const IOSShadingPrototypePlan tile =
      iosShadingPrototypePlan(IOSShadingPrototypeKind::TileDeferred);
  const IOSShadingPrototypePlan forward =
      iosShadingPrototypePlan(IOSShadingPrototypeKind::ForwardPlus);
  if(!tile.framePlan.validate() || !tile.validate() ||
     !forward.framePlan.validate() || !forward.validate())
    return 1;
  if(checkTilePlan(tile)!=0 || checkForwardPlan(forward)!=0)
    return 2;
  if(tile.common!=forward.common ||
     tile.common!=iosShadingPrototypeCommonContract() ||
     tile.runtime!=forward.runtime ||
     tile.runtime!=iosShadingPrototypeRuntimeContract())
    return 3;

  const IOSShadingPrototypePlanSelection tileSelection =
      iosShadingPrototypeSelectPlan(tile);
  const IOSShadingPrototypePlanSelection forwardSelection =
      iosShadingPrototypeSelectPlan(forward);
  if(!tileSelection ||
     tileSelection.kind!=IOSShadingPrototypeKind::TileDeferred ||
     tileSelection.presentResource!=0u ||
     tileSelection.outputResource!=1u ||
     tileSelection.workingResource!=2u ||
     tileSelection.computePass!=IOSShadingPrototypeNoPass ||
     tileSelection.renderPass!=0u ||
     tileSelection.presentPass!=1u)
    return 4;
  if(!forwardSelection ||
     forwardSelection.kind!=IOSShadingPrototypeKind::ForwardPlus ||
     forwardSelection.presentResource!=0u ||
     forwardSelection.outputResource!=1u ||
     forwardSelection.workingResource!=2u ||
     forwardSelection.computePass!=0u ||
     forwardSelection.renderPass!=1u ||
     forwardSelection.presentPass!=2u)
    return 5;

  {
    IOSShadingPrototypePlan invalid = tile;
    invalid.framePlan.passes.pop_back();
    const IOSShadingPrototypePlanValidation validation = invalid.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(invalid);
    if(validation.error!=IOSShadingPrototypePlanError::InvalidFramePlan ||
       validation.framePlan.error!=IOSFramePlanError::MissingPresent ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Invalid)
      return 6;
  }
  {
    IOSShadingPrototypePlan unsupported = tile;
    unsupported.framePlan.resources[0].layout.extent.width = 8u;
    const IOSShadingPrototypePlanValidation validation =
        unsupported.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unsupported);
    if(!unsupported.framePlan.validate() ||
       validation.error!=IOSShadingPrototypePlanError::FramePlanMismatch ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Unsupported)
      return 7;
  }
  {
    IOSShadingPrototypePlan unsupported = tile;
    unsupported.common.lightInputs = 2u;
    const IOSShadingPrototypePlanValidation validation =
        unsupported.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unsupported);
    if(!unsupported.framePlan.validate() ||
       validation.error!=
         IOSShadingPrototypePlanError::CommonContractMismatch ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Unsupported)
      return 8;
  }
  {
    IOSShadingPrototypePlan unsupported = tile;
    unsupported.runtime.commits = 1u;
    const IOSShadingPrototypePlanValidation validation =
        unsupported.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unsupported);
    if(!unsupported.framePlan.validate() ||
       validation.error!=
         IOSShadingPrototypePlanError::RuntimeContractMismatch ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Unsupported)
      return 9;
  }
  {
    IOSShadingPrototypePlan unsupported = tile;
    unsupported.topology.draws = 3u;
    const IOSShadingPrototypePlanValidation validation =
        unsupported.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unsupported);
    if(!unsupported.framePlan.validate() ||
       validation.error!=IOSShadingPrototypePlanError::TopologyMismatch ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Unsupported)
      return 10;
  }
  {
    IOSShadingPrototypePlan unsupported = tile;
    unsupported.topology.operations[1] =
        IOSShadingPrototypeOperation::DrawOpaque;
    const IOSShadingPrototypePlanValidation validation =
        unsupported.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unsupported);
    if(!unsupported.framePlan.validate() ||
       validation.error!=IOSShadingPrototypePlanError::TopologyMismatch ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Unsupported)
      return 11;
  }
  {
    IOSShadingPrototypePlan unknown = tile;
    unknown.kind = static_cast<IOSShadingPrototypeKind>(0xffu);
    const IOSShadingPrototypePlanValidation validation = unknown.validate();
    const IOSShadingPrototypePlanSelection selection =
        iosShadingPrototypeSelectPlan(unknown);
    if(validation.error!=IOSShadingPrototypePlanError::UnsupportedKind ||
       selection.status!=IOSShadingPrototypeSelectionStatus::Invalid)
      return 12;
  }

  uint32_t mutationCount = 0u;
  for(const IOSShadingPrototypeKind kind:Kinds) {
    for(const CommonField field:CommonFields) {
      ++mutationCount;
      if(!rejects(kind,[field](IOSShadingPrototypePlan& plan) {
           mutate(plan.common,field);
         }))
        return 100;
      }
    for(const TopologyField field:TopologyFields) {
      ++mutationCount;
      if(!rejects(kind,[field](IOSShadingPrototypePlan& plan) {
           mutate(plan.topology,field);
         }))
        return 101;
      }
    for(const RuntimeField field:RuntimeFields) {
      ++mutationCount;
      if(!rejects(kind,[field](IOSShadingPrototypePlan& plan) {
           mutate(plan.runtime,field);
         }))
        return 102;
      }

    const IOSShadingPrototypePlan canonical =
        iosShadingPrototypePlan(kind);
    for(uint32_t resourceIndex=0u;
        resourceIndex<canonical.framePlan.resources.size();
        ++resourceIndex) {
      for(const ResourceField field:ResourceFields) {
        ++mutationCount;
        if(!rejects(
             kind,
             [resourceIndex,field](IOSShadingPrototypePlan& plan) {
               mutate(plan.framePlan.resources[resourceIndex],field);
             }))
          return 103;
        }
      }
    for(uint32_t passIndex=0u;
        passIndex<canonical.framePlan.passes.size();
        ++passIndex) {
      for(const PassField field:PassFields) {
        ++mutationCount;
        if(!rejects(
             kind,
             [passIndex,field](IOSShadingPrototypePlan& plan) {
               mutate(plan.framePlan.passes[passIndex],field);
             }))
          return 104;
        }
      for(uint32_t useIndex=0u;
          useIndex<canonical.framePlan.passes[passIndex].uses.size();
          ++useIndex) {
        for(const UseField field:UseFields) {
          ++mutationCount;
          if(!rejects(
               kind,
               [passIndex,useIndex,field](
                   IOSShadingPrototypePlan& plan) {
                 mutate(
                   plan.framePlan.passes[passIndex].uses[useIndex],
                   field);
               }))
            return 105;
          }
        }

      ++mutationCount;
      if(!rejects(
           kind,
           [passIndex](IOSShadingPrototypePlan& plan) {
             plan.framePlan.passes[passIndex].uses.pop_back();
           }))
        return 106;
      ++mutationCount;
      if(!rejects(
           kind,
           [passIndex](IOSShadingPrototypePlan& plan) {
             plan.framePlan.passes[passIndex].uses.push_back(
                 plan.framePlan.passes[passIndex].uses.back());
           }))
        return 107;
      }

    ++mutationCount;
    if(!rejects(kind,[](IOSShadingPrototypePlan& plan) {
         plan.framePlan.resources.pop_back();
       }))
      return 108;
    ++mutationCount;
    if(!rejects(kind,[](IOSShadingPrototypePlan& plan) {
         plan.framePlan.resources.push_back(
             plan.framePlan.resources.back());
       }))
      return 109;
    ++mutationCount;
    if(!rejects(kind,[](IOSShadingPrototypePlan& plan) {
         plan.framePlan.passes.pop_back();
       }))
      return 110;
    ++mutationCount;
    if(!rejects(kind,[](IOSShadingPrototypePlan& plan) {
         plan.framePlan.passes.push_back(
             plan.framePlan.passes.back());
       }))
      return 111;

    ++mutationCount;
    if(!rejects(kind,[kind](IOSShadingPrototypePlan& plan) {
         plan.kind =
             kind==IOSShadingPrototypeKind::TileDeferred
               ? IOSShadingPrototypeKind::ForwardPlus
               : IOSShadingPrototypeKind::TileDeferred;
       }))
      return 112;
    }

  ++mutationCount;
  if(!rejects(
       IOSShadingPrototypeKind::TileDeferred,
       [](IOSShadingPrototypePlan& plan) {
         plan.kind = static_cast<IOSShadingPrototypeKind>(0xffu);
       }))
    return 113;

  if(mutationCount!=214u)
    return 114;
  return 0;
  }
