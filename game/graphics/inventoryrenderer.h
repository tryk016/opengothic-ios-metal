#pragma once

#include <Tempest/Device>
#include <Tempest/Matrix4x4>

#include <cstdint>

#include "meshobjects.h"
#include "sceneglobals.h"
#include "visualobjects.h"

class Item;

#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
enum class RendererIOSUISurfaceEvidence : uint8_t {
  None,
  Inventory,
  QuickRingItems,
  QuickRingWeapons,
  };
#endif

class InventoryRenderer {
  public:
    InventoryRenderer();

    uint64_t draw(Tempest::Encoder<Tempest::CommandBuffer>& cmd);

    void reset(bool full=false);
    void drawItem(int x, int y, int w, int h, const Item &item);
    bool hasItems() const { return !items.empty(); }
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    void setRendererIOSUISurfaceEvidence(
      RendererIOSUISurfaceEvidence value) noexcept {
      rendererIOSUISurfaceEvidence = value;
      }
    void clearRendererIOSUISurfaceEvidence() noexcept {
      rendererIOSUISurfaceEvidence = RendererIOSUISurfaceEvidence::None;
      }
    RendererIOSUISurfaceEvidence rendererIOSUISurface() const noexcept {
      return rendererIOSUISurfaceEvidence;
      }
#endif

  private:
    struct PerFrame {
      Tempest::Matrix4x4 mvp;
      };

    struct Itm {
      MeshObjects::Mesh  mesh;
      Tempest::Matrix4x4 viewMat;
      int x=0, y=0, w=0, h=0;
      };

    SceneGlobals     scene;
    VisualObjects    visual;
    MeshObjects      itmGroup;
    std::vector<Itm> items;
#if defined(__IOS__) && defined(OPENGOTHIC_RENDERER_IOS_DIAGNOSTICS)
    RendererIOSUISurfaceEvidence rendererIOSUISurfaceEvidence =
      RendererIOSUISurfaceEvidence::None;
#endif
  };
