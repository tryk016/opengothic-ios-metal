#include "iosshadingprototypeplan.h"

namespace {

bool known(IOSShadingPrototypeKind kind) noexcept {
  switch(kind) {
    case IOSShadingPrototypeKind::TileDeferred:
    case IOSShadingPrototypeKind::ForwardPlus:
      return true;
    }
  return false;
  }

IOSResourceDesc presentResource() noexcept {
  return {
    IOSResourceId{1u},
    IOSResourceKind::Texture,
    IOSResourceLifetime::External,
    IOSInitialContent::Defined,
    false,
    false,
    IOSAliasGroupId{},
    {
      IOSPixelFormat::Bgra8Unorm,
      {4u,4u},
      1u,
      1u,
      0u,
    },
    IOSResourceUsage::Present,
    };
  }

IOSResourceDesc outputResource() noexcept {
  return {
    IOSResourceId{2u},
    IOSResourceKind::Texture,
    IOSResourceLifetime::Transient,
    IOSInitialContent::Undefined,
    false,
    false,
    IOSAliasGroupId{},
    {
      IOSPixelFormat::Rgba8Unorm,
      {4u,4u},
      1u,
      1u,
      0u,
    },
    IOSResourceUsage::RenderAttachment,
    };
  }

IOSResourceDesc compactMaterialResource() noexcept {
  IOSResourceDesc resource = outputResource();
  resource.id = IOSResourceId{3u};
  resource.memoryless = true;
  return resource;
  }

IOSResourceDesc lightListResource() noexcept {
  return {
    IOSResourceId{3u},
    IOSResourceKind::Buffer,
    IOSResourceLifetime::Transient,
    IOSInitialContent::Undefined,
    false,
    false,
    IOSAliasGroupId{},
    {
      IOSPixelFormat::Undefined,
      {0u,0u},
      0u,
      0u,
      256u,
    },
    IOSResourceUsage::ShaderRead|IOSResourceUsage::ShaderWrite,
    };
  }

IOSResourceUse outputUse() noexcept {
  return {
    IOSResourceId{2u},
    IOSUseSemantic::RenderAttachment,
    IOSLoadAction::Clear,
    IOSStoreAction::Store,
    IOSAttachmentWriteMode::FullOverwrite,
    };
  }

IOSResourceUse compactMaterialUse() noexcept {
  return {
    IOSResourceId{3u},
    IOSUseSemantic::RenderAttachment,
    IOSLoadAction::Discard,
    IOSStoreAction::Discard,
    IOSAttachmentWriteMode::FullOverwrite,
    };
  }

IOSResourceUse lightListWriteUse() noexcept {
  return {
    IOSResourceId{3u},
    IOSUseSemantic::FullOverwrite,
    IOSLoadAction::NotApplicable,
    IOSStoreAction::NotApplicable,
    IOSAttachmentWriteMode::NotApplicable,
    };
  }

IOSResourceUse lightListReadUse() noexcept {
  return {
    IOSResourceId{3u},
    IOSUseSemantic::Read,
    IOSLoadAction::NotApplicable,
    IOSStoreAction::NotApplicable,
    IOSAttachmentWriteMode::NotApplicable,
    };
  }

IOSResourceUse presentUse() noexcept {
  return {
    IOSResourceId{1u},
    IOSUseSemantic::PresentSource,
    IOSLoadAction::NotApplicable,
    IOSStoreAction::NotApplicable,
    IOSAttachmentWriteMode::NotApplicable,
    };
  }

IOSShadingPrototypeTopology tileTopology() noexcept {
  return {
    1u,
    1u,
    1u,
    2u,
    1u,
    0u,
    0u,
    0u,
    3u,
    {
      IOSShadingPrototypeOperation::DrawOpaque,
      IOSShadingPrototypeOperation::DrawAlphaTest,
      IOSShadingPrototypeOperation::DispatchTileLighting,
    },
    };
  }

IOSShadingPrototypeTopology forwardTopology() noexcept {
  return {
    1u,
    1u,
    1u,
    2u,
    0u,
    1u,
    0u,
    0u,
    3u,
    {
      IOSShadingPrototypeOperation::BuildLightList,
      IOSShadingPrototypeOperation::DrawOpaque,
      IOSShadingPrototypeOperation::DrawAlphaTest,
    },
    };
  }

IOSFramePlan tileFramePlan() {
  IOSFramePlan plan;
  plan.resources = {
    presentResource(),
    outputResource(),
    compactMaterialResource(),
    };
  plan.passes = {
    {
      IOSPassId{1u},
      IOSPassKind::Render,
      {
        outputUse(),
        compactMaterialUse(),
      },
    },
    {
      IOSPassId{2u},
      IOSPassKind::Present,
      {
        presentUse(),
      },
    },
    };
  return plan;
  }

IOSFramePlan forwardFramePlan() {
  IOSFramePlan plan;
  plan.resources = {
    presentResource(),
    outputResource(),
    lightListResource(),
    };
  plan.passes = {
    {
      IOSPassId{1u},
      IOSPassKind::Compute,
      {
        lightListWriteUse(),
      },
    },
    {
      IOSPassId{2u},
      IOSPassKind::Render,
      {
        outputUse(),
        lightListReadUse(),
      },
    },
    {
      IOSPassId{3u},
      IOSPassKind::Present,
      {
        presentUse(),
      },
    },
    };
  return plan;
  }

bool exact(const IOSResourceDesc& lhs,
           const IOSResourceDesc& rhs) noexcept {
  return lhs.id==rhs.id &&
         lhs.kind==rhs.kind &&
         lhs.lifetime==rhs.lifetime &&
         lhs.initialContent==rhs.initialContent &&
         lhs.memoryless==rhs.memoryless &&
         lhs.aliasable==rhs.aliasable &&
         lhs.aliasGroup==rhs.aliasGroup &&
         lhs.layout==rhs.layout &&
         lhs.usage==rhs.usage;
  }

bool exact(const IOSResourceUse& lhs,
           const IOSResourceUse& rhs) noexcept {
  return lhs.resource==rhs.resource &&
         lhs.semantic==rhs.semantic &&
         lhs.load==rhs.load &&
         lhs.store==rhs.store &&
         lhs.attachmentWriteMode==rhs.attachmentWriteMode;
  }

bool exactTileFramePlan(const IOSFramePlan& plan) noexcept {
  return plan.resources.size()==3u &&
         plan.passes.size()==2u &&
         exact(plan.resources[0],presentResource()) &&
         exact(plan.resources[1],outputResource()) &&
         exact(plan.resources[2],compactMaterialResource()) &&
         plan.passes[0].id==IOSPassId{1u} &&
         plan.passes[0].kind==IOSPassKind::Render &&
         plan.passes[0].uses.size()==2u &&
         exact(plan.passes[0].uses[0],outputUse()) &&
         exact(plan.passes[0].uses[1],compactMaterialUse()) &&
         plan.passes[1].id==IOSPassId{2u} &&
         plan.passes[1].kind==IOSPassKind::Present &&
         plan.passes[1].uses.size()==1u &&
         exact(plan.passes[1].uses[0],presentUse());
  }

bool exactForwardFramePlan(const IOSFramePlan& plan) noexcept {
  return plan.resources.size()==3u &&
         plan.passes.size()==3u &&
         exact(plan.resources[0],presentResource()) &&
         exact(plan.resources[1],outputResource()) &&
         exact(plan.resources[2],lightListResource()) &&
         plan.passes[0].id==IOSPassId{1u} &&
         plan.passes[0].kind==IOSPassKind::Compute &&
         plan.passes[0].uses.size()==1u &&
         exact(plan.passes[0].uses[0],lightListWriteUse()) &&
         plan.passes[1].id==IOSPassId{2u} &&
         plan.passes[1].kind==IOSPassKind::Render &&
         plan.passes[1].uses.size()==2u &&
         exact(plan.passes[1].uses[0],outputUse()) &&
         exact(plan.passes[1].uses[1],lightListReadUse()) &&
         plan.passes[2].id==IOSPassId{3u} &&
         plan.passes[2].kind==IOSPassKind::Present &&
         plan.passes[2].uses.size()==1u &&
         exact(plan.passes[2].uses[0],presentUse());
  }

IOSShadingPrototypePlan canonical(
    IOSShadingPrototypeKind kind) {
  IOSShadingPrototypePlan plan;
  plan.kind = kind;
  plan.common = iosShadingPrototypeCommonContract();
  plan.runtime = iosShadingPrototypeRuntimeContract();
  if(kind==IOSShadingPrototypeKind::TileDeferred) {
    plan.topology = tileTopology();
    plan.framePlan = tileFramePlan();
    }
  else if(kind==IOSShadingPrototypeKind::ForwardPlus) {
    plan.topology = forwardTopology();
    plan.framePlan = forwardFramePlan();
    }
  return plan;
  }

}

IOSShadingPrototypeCommonContract
    iosShadingPrototypeCommonContract() noexcept {
  return {};
  }

IOSShadingPrototypeRuntimeContract
    iosShadingPrototypeRuntimeContract() noexcept {
  return {};
  }

IOSShadingPrototypePlan
    iosShadingPrototypePlan(IOSShadingPrototypeKind kind) {
  return canonical(kind);
  }

IOSShadingPrototypePlanValidation
    IOSShadingPrototypePlan::validate() const noexcept {
  if(!known(kind))
    return {IOSShadingPrototypePlanError::UnsupportedKind,{}};

  const IOSFramePlanValidation frameValidation = framePlan.validate();
  if(!frameValidation)
    return {
      IOSShadingPrototypePlanError::InvalidFramePlan,
      frameValidation,
      };

  if(common!=iosShadingPrototypeCommonContract())
    return {IOSShadingPrototypePlanError::CommonContractMismatch,{}};
  if(runtime!=iosShadingPrototypeRuntimeContract())
    return {IOSShadingPrototypePlanError::RuntimeContractMismatch,{}};
  const IOSShadingPrototypeTopology expectedTopology =
      kind==IOSShadingPrototypeKind::TileDeferred
        ? tileTopology()
        : forwardTopology();
  if(topology!=expectedTopology)
    return {IOSShadingPrototypePlanError::TopologyMismatch,{}};
  const bool exactFrame =
      kind==IOSShadingPrototypeKind::TileDeferred
        ? exactTileFramePlan(framePlan)
        : exactForwardFramePlan(framePlan);
  if(!exactFrame)
    return {IOSShadingPrototypePlanError::FramePlanMismatch,{}};
  return {};
  }

IOSShadingPrototypePlanSelection
    iosShadingPrototypeSelectPlan(
        const IOSShadingPrototypePlan& plan) noexcept {
  IOSShadingPrototypePlanSelection result;
  result.kind = plan.kind;
  const IOSShadingPrototypePlanValidation validation = plan.validate();
  if(!validation) {
    if(validation.error==IOSShadingPrototypePlanError::UnsupportedKind ||
       validation.error==IOSShadingPrototypePlanError::InvalidFramePlan)
      result.status = IOSShadingPrototypeSelectionStatus::Invalid;
    return result;
    }

  result.status = IOSShadingPrototypeSelectionStatus::Supported;
  result.presentResource = 0u;
  result.outputResource = 1u;
  result.workingResource = 2u;
  if(plan.kind==IOSShadingPrototypeKind::TileDeferred) {
    result.computePass = IOSShadingPrototypeNoPass;
    result.renderPass = 0u;
    result.presentPass = 1u;
    }
  else {
    result.computePass = 0u;
    result.renderPass = 1u;
    result.presentPass = 2u;
    }
  return result;
  }
