#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "utils/keycodec.h"

namespace Tempest { class Painter; }
class InventoryRenderer;
class Item;
class Npc;

// A modal radial selector driven by the right stick. Both panels use fixed,
// always-visible slots arranged in two concentric rows. Items are activated
// here; weapon/spell cells return the semantic action which PlayerControl must
// dispatch so that normal draw/sheathe animation queuing remains in charge.
class QuickRing {
  public:
    enum Kind : uint8_t {
      Items,
      Weapons,
      };

    explicit QuickRing(Kind k);
    ~QuickRing();

    bool isOpen() const { return opened; }
    void open (Npc& pl);                        // rebuild fixed slots
    void updateSelection(float sx, float sy);   // right-stick/touch aim
    void close();                               // dismiss without acting

    // Item cells are used immediately and return nullopt. Weapon/magic cells
    // return the action that the caller must pulse through PlayerControl.
    std::optional<KeyCodec::Action> commit(Npc& pl);

    void paint(Tempest::Painter& p, InventoryRenderer& ir, const Npc* pl,
               int screenW, int screenH, float scale) const;

  private:
    enum class Band : uint8_t { None, Inner, Outer };
    enum class CellType : uint8_t { Empty, Item, Action };

    struct Cell {
      size_t           cls      = 0;
      int              count    = 0;
      bool             equipped = false;
      CellType         type     = CellType::Empty;
      KeyCodec::Action action   = KeyCodec::Idle;
      std::string      name;

      bool valid() const { return type!=CellType::Empty; }
      };

    static constexpr int ITEM_INNER_CELLS  = 4;
    static constexpr int ITEM_OUTER_CELLS  = 9;
    static constexpr int WEAPON_INNER_CELLS = 2;
    static constexpr int WEAPON_OUTER_CELLS = 7;
    static constexpr int MAX_CELLS = ITEM_INNER_CELLS + ITEM_OUTER_CELLS;

    static constexpr float SELECT_EPS       = 0.28f;
    static constexpr float BAND_TO_INNER    = 0.62f;
    static constexpr float BAND_TO_OUTER    = 0.72f;
    static constexpr float BAND_FIRST_OUTER = 0.67f;

    int innerCells() const;
    int outerCells() const;
    int cellsCount () const;

    Kind                   kind;
    bool                   opened = false;
    std::array<Cell,MAX_CELLS> cells{};
    int                    sel  = -1;
    Band                   band = Band::None;

    // A burning torch is removed from Inventory. Keep a display-only item so
    // its assigned synthetic cell still has the regular 3D inventory icon.
    std::unique_ptr<Item> syntheticTorch;
  };
