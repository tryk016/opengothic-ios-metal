#include "paddiagram.h"

#include <Tempest/Painter>
#include <Tempest/Brush>
#include <Tempest/Color>
#include <Tempest/Texture2d>

#include <algorithm>
#include <array>
#include <cstdio>
#include <initializer_list>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>

#include "game/constants.h"
#include "utils/gthfont.h"
#include "ui/padglyph.h"

using namespace Tempest;

namespace {

struct Loc {
  const char* title;
  const char* itemRing;
  const char* move;
  const char* walkRun;
  const char* melee;
  const char* ranged;
  const char* quickSlots;
  const char* parry;
  const char* magicRing;
  const char* weapon;
  const char* jump;
  const char* sneak;
  const char* action;
  const char* camera;
  const char* targetLock;
  const char* inventory;
  const char* gameMenu;
  const char* quickSave;
  const char* quickLoad;
  const char* unstuck;
  const char* hold;
  };

// GthFont maps one byte to one glyph in the game codepage, not UTF-8. PL uses
// CP1250, DE CP1252. Hex escapes are split ("\xB3" "a") wherever the next
// character is a hex digit, or it would be swallowed by the escape.
const Loc& loc(ScriptLang language) {
  static const Loc en = {
    "Controller layout",
    "Item wheel",
    "Move / Turn",
    "Walk / Run",
    "Melee weapon",
    "Ranged weapon",
    "Quick slot 1 / 2",
    "Parry",
    "Magic wheel",
    "Draw / sheathe weapon",
    "Jump / Climb",
    "Sneak",
    "Action / Attack",
    "Camera",
    "Target lock",
    "Inventory",
    "Game menu",
    "Quick save",
    "Quick load",
    "Teleport when stuck",
    "hold",
    };
  static const Loc de = {
    "Controller-Belegung",
    "Gegenstands-Rad",
    "Bewegen / Drehen",
    "Gehen / Laufen",
    "Nahkampfwaffe",
    "Fernkampfwaffe",
    "Schnellslot 1 / 2",
    "Parieren",
    "Magie-Rad",
    "Waffe ziehen / wegstecken",
    "Springen / Klettern",
    "Schleichen",
    "Aktion / Angriff",
    "Kamera",
    "Ziel fixieren",
    "Inventar",
    "Spielermen\xFC",
    "Schnellspeichern",
    "Schnellladen",
    "Teleport, wenn man feststeckt",
    "halten",
    };
  static const Loc pl = {
    "Uk\xB3" "ad kontrolera",
    "Ko\xB3o przedmiot\xF3w",
    "Ruch / skr\xEAt",
    "Ch\xF3" "d / bieg",
    "Bro\xF1 bia\xB3" "a",
    "Bro\xF1 dystansowa",
    "Szybki slot 1 / 2",
    "Parowanie",
    "Ko\xB3o magii",
    "Dob\xB9" "d\x9F / schowaj bro\xF1",
    "Skok / wspinaczka",
    "Skradanie",
    "Akcja / atak",
    "Kamera",
    "Blokada celu",
    "Ekwipunek",
    "Menu gry",
    "Szybki zapis",
    "Szybkie wczytanie",
    "Teleport, gdy posta\xE6 utknie",
    "przytrzymaj",
    };
  switch(language) {
    case ScriptLang::DE: return de;
    case ScriptLang::PL: return pl;
    default:             return en;
    }
  }

// One labelled callout: up to two glyphs, a text and the leader-line anchor in
// normalized diagram coordinates. Anchors were measured on the Xelu line-art.
struct Row {
  PadGlyph::Btn g1;
  PadGlyph::Btn g2;
  uint8_t       ng;
  const char*   txt;
  float         ax, ay;
  };

struct WrappedLabel {
  std::string line1;
  std::string line2;

  int lines() const {
    return line2.empty() ? 1 : 2;
    }
  };

// Split only on ASCII spaces: the labels use the game's one-byte CP1250/
// CP1252 encoding, so byte-wise word boundaries are safe while UTF-8 rules
// would not be. The best balanced split is used and the result never exceeds
// two lines.
WrappedLabel wrapLabel(const GthFont& fnt, const char* text, int maxWidth) {
  const std::string_view full(text);
  if(fnt.textSize(full).w<=maxWidth)
    return {std::string(full),{}};

  WrappedLabel best = {std::string(full),{}};
  int  bestWidth = std::numeric_limits<int>::max();
  bool bestFits  = false;

  for(size_t split=full.find(' '); split!=std::string_view::npos;
      split=full.find(' ',split+1)) {
    size_t leftEnd = split;
    while(leftEnd>0 && full[leftEnd-1]==' ')
      --leftEnd;
    size_t rightBeg = split+1;
    while(rightBeg<full.size() && full[rightBeg]==' ')
      ++rightBeg;
    if(leftEnd==0 || rightBeg==full.size())
      continue;

    std::string first(full.substr(0,leftEnd));
    std::string second(full.substr(rightBeg));
    const int w1 = fnt.textSize(first).w;
    const int w2 = fnt.textSize(second).w;
    const int widest = std::max(w1,w2);
    const bool fits = widest<=maxWidth;
    if((fits && !bestFits) || (fits==bestFits && widest<bestWidth)) {
      best      = {std::move(first),std::move(second)};
      bestWidth = widest;
      bestFits  = fits;
      }
    }

  // A German compound (or a very narrow panel) may have no usable word
  // boundary. The game strings are single-byte encoded, so a last-resort
  // character split is safe and still keeps the complete label visible.
  if(!bestFits) {
    for(size_t split=1; split<full.size(); ++split) {
      size_t leftEnd = split;
      while(leftEnd>0 && full[leftEnd-1]==' ')
        --leftEnd;
      size_t rightBeg = split;
      while(rightBeg<full.size() && full[rightBeg]==' ')
        ++rightBeg;
      if(leftEnd==0 || rightBeg==full.size())
        continue;

      std::string first(full.substr(0,leftEnd));
      std::string second(full.substr(rightBeg));
      const int widest = std::max(fnt.textSize(first).w,
                                  fnt.textSize(second).w);
      const bool fits = widest<=maxWidth;
      if((fits && !bestFits) || (fits==bestFits && widest<bestWidth)) {
        best      = {std::move(first),std::move(second)};
        bestWidth = widest;
        bestFits  = fits;
        }
      }
    }
  return best;
  }

int minimumTwoLineWidth(const GthFont& fnt, const char* text) {
  const std::string_view full(text);
  int best = fnt.textSize(full).w;
  for(size_t split=1; split<full.size(); ++split) {
    size_t leftEnd = split;
    while(leftEnd>0 && full[leftEnd-1]==' ')
      --leftEnd;
    size_t rightBeg = split;
    while(rightBeg<full.size() && full[rightBeg]==' ')
      ++rightBeg;
    if(leftEnd==0 || rightBeg==full.size())
      continue;
    best = std::min(best,std::max(fnt.textSize(full.substr(0,leftEnd)).w,
                                 fnt.textSize(full.substr(rightBeg)).w));
    }
  return best;
  }
}

bool PadDiagram::available() {
  return PadGlyph::diagram()!=nullptr;
  }

void PadDiagram::draw(Painter& p, const GthFont& fnt, int w, int h, float scale,
                      ScriptLang language, bool reserveVersionLine) {
  const Texture2d* img = PadGlyph::diagram();
  if(img==nullptr)
    return;

  const Loc& L = loc(language);

  // Dim the whole page: the parchment menu background is too busy behind the
  // thin white line-art.
  p.setBrush(Color(0.f,0.f,0.f,0.62f));
  p.drawRect(0,0,w,h);

  const int   th     = fnt.pixelSize();
  const int   s      = std::max(18, int(26.f*scale));       // glyph side
  const int   rowH   = std::max(s,th) + int(8.f*scale);
  const int   gap    = int(10.f*scale);
  const int   tokGap = int(6.f*scale);
  const int   margin = int(18.f*scale);
  const int   lineT  = std::max(1, int(2.f*scale));
  const int   textGap= std::max(1, int(2.f*scale));
  const int   footerRowH = std::max(rowH,2*th+textGap+int(4.f*scale));
  const Color ink    = Color(0.86f,0.78f,0.60f,0.65f);

  // Title.
  const auto ts = fnt.textSize(L.title);
  fnt.drawText(p, (w-ts.w)/2, margin+ts.h, L.title);

  // Vertical bands: title / View+Menu callouts / diagram / combo footer.
  const int topBandY = margin + ts.h + int(10.f*scale);
  const int imgTop   = topBandY + s + int(14.f*scale);

  // The menu draws its build string after this page. Reserve its real glyph
  // box explicitly so the two combo rows can never overlap it.
  const int versionTop  = reserveVersionLine ? h-int(25.f*scale)-th : h;
  const int footerBot   = std::min(h-margin, versionTop-gap);
  const int cy2         = footerBot-footerRowH/2;
  const int cy1         = cy2-footerRowH;
  const int imgBot      = std::max(imgTop+1,
                                  cy1-footerRowH/2-int(12.f*scale));

  auto widestTwoLine = [&](std::initializer_list<const char*> labels) {
    int ret = 0;
    for(const char* label:labels)
      ret = std::max(ret,minimumTwoLineWidth(fnt,label));
    return ret;
    };
  const int leftSingleW = widestTwoLine({L.itemRing,L.move,L.walkRun,L.melee,L.ranged});
  const int leftDoubleW = minimumTwoLineWidth(fnt,L.quickSlots) + s+tokGap/2;
  const int rightW = widestTwoLine({L.parry,L.magicRing,L.weapon,L.jump,
                                    L.sneak,L.action,L.camera,L.targetLock});
  const int requiredColW = margin+2*gap+s+
                           std::max({leftSingleW,leftDoubleW,rightW});
  const int maxColW = std::max(1,(w-4*s)/2);
  const int colW = std::clamp(std::max(int(float(w)*0.30f),requiredColW),
                              1,maxColW);

  // Fit the line-art into the middle band, keeping aspect.
  const int   availW = w - 2*colW;
  const int   availH = std::max(1, imgBot-imgTop);
  const float ratio  = std::min(float(availW)/float(img->w()),
                                float(availH)/float(img->h()));
  const int   dw     = int(float(img->w())*ratio);
  const int   dh     = int(float(img->h())*ratio);
  const int   imgX   = colW   + (availW-dw)/2;
  const int   imgY   = imgTop + (availH-dh)/2;

  p.setBrush(Brush(*img, Color(1.f,1.f,1.f,0.92f)));
  p.drawRect(imgX,imgY,dw,dh, 0,0,int(img->w()),int(img->h()));

  auto hline = [&](int x0, int x1, int y) {
    if(x1<x0)
      std::swap(x0,x1);
    p.setBrush(ink);
    p.drawRect(x0,y-lineT/2, x1-x0, lineT);
    };
  auto vline = [&](int x, int y0, int y1) {
    if(y1<y0)
      std::swap(y0,y1);
    p.setBrush(ink);
    p.drawRect(x-lineT/2,y0, lineT, y1-y0);
    };
  auto dot = [&](int x, int y) {
    p.setBrush(ink);
    p.drawRect(x-lineT,y-lineT, 2*lineT, 2*lineT);
    };
  // The compact hint bar maps the D-pad to keyboard-arrow art; the diagram
  // wants the real pad glyphs, so try those first.
  auto glyph = [&](PadGlyph::Btn b, int x, int y) {
    if(const Texture2d* t = PadGlyph::dpadTexture(b)) {
      p.setBrush(Brush(*t, Color(1.f,1.f,1.f,1.f)));
      p.drawRect(x,y,s,s, 0,0,int(t->w()),int(t->h()));
      return;
      }
    PadGlyph::draw(p,fnt,b,x,y,s);
    };

  // Keep in sync with GamepadInput::tickWorld. Sorted by anchor height so the
  // height-aware callout rows roughly track their buttons.
  const Row left[] = {
    {PadGlyph::LT,       PadGlyph::LT,        1, L.itemRing,   0.251f,0.068f},
    {PadGlyph::LStick,   PadGlyph::LStick,    1, L.move,       0.260f,0.446f},
    {PadGlyph::L3,       PadGlyph::L3,        1, L.walkRun,    0.260f,0.490f},
    {PadGlyph::DPadUp,   PadGlyph::DPadUp,    1, L.melee,      0.378f,0.595f},
    {PadGlyph::DPadLeft, PadGlyph::DPadRight, 2, L.quickSlots, 0.345f,0.643f},
    {PadGlyph::DPadDown, PadGlyph::DPadDown,  1, L.ranged,     0.378f,0.690f},
    };
  const Row right[] = {
    {PadGlyph::RT,     PadGlyph::RT,     1, L.parry,      0.752f,0.068f},
    {PadGlyph::RB,     PadGlyph::RB,     1, L.magicRing,  0.732f,0.137f},
    {PadGlyph::Y,      PadGlyph::Y,      1, L.weapon,     0.751f,0.334f},
    {PadGlyph::B,      PadGlyph::B,      1, L.jump,       0.817f,0.420f},
    {PadGlyph::X,      PadGlyph::X,      1, L.sneak,      0.683f,0.425f},
    {PadGlyph::A,      PadGlyph::A,      1, L.action,     0.748f,0.514f},
    {PadGlyph::RStick, PadGlyph::RStick, 1, L.camera,     0.622f,0.648f},
    {PadGlyph::R3,     PadGlyph::R3,     1, L.targetLock, 0.622f,0.690f},
    };

  auto prepareLabels = [&](const auto& rows, bool onLeft) {
    constexpr size_t count = std::extent_v<std::remove_reference_t<decltype(rows)>>;
    std::array<WrappedLabel,count> labels;
    for(size_t i=0; i<std::size(rows); ++i) {
      int maxWidth = 0;
      if(onLeft) {
        int gx = imgX-gap-s;
        if(rows[i].ng==2)
          gx -= s+tokGap/2;
        maxWidth = gx-gap-margin;
        }
      else {
        const int textX = imgX+dw+gap+s+gap;
        maxWidth = w-margin-textX;
        }
      labels[i] = wrapLabel(fnt,rows[i].txt,std::max(1,maxWidth));
      }
    return labels;
    };

  const auto leftLabels  = prepareLabels(left, true);
  const auto rightLabels = prepareLabels(right,false);

  auto blockHeight = [&](const WrappedLabel& label) {
    const int textH = label.lines()*th + (label.lines()-1)*textGap;
    return std::max(s,textH);
    };
  auto layoutRows = [&](const auto& labels) {
    constexpr size_t count = std::tuple_size_v<std::decay_t<decltype(labels)>>;
    std::array<int,count> centers = {};
    int total = 0;
    for(const auto& label:labels)
      total += blockHeight(label);

    const int bandH = std::max(1,imgBot-imgTop);
    const int free  = std::max(0,bandH-total);
    const int rowsGap = labels.size()>1 ? free/int(labels.size()-1) : 0;
    const int used = total + rowsGap*int(labels.size()-1);
    int y = imgTop + std::max(0,(bandH-used)/2);
    for(size_t i=0; i<labels.size(); ++i) {
      const int bh = blockHeight(labels[i]);
      centers[i] = y+bh/2;
      y += bh+rowsGap;
      }
    return centers;
    };

  const auto leftCy  = layoutRows(leftLabels);
  const auto rightCy = layoutRows(rightLabels);

  auto drawLabel = [&](const WrappedLabel& label, int edge, int cy,
                       bool alignRight) {
    auto line = [&](const std::string& text, int baseline) {
      const int x = alignRight ? edge-fnt.textSize(text).w : edge;
      fnt.drawText(p,x,baseline,text.c_str());
      };
    if(label.line2.empty()) {
      line(label.line1,cy+th/2);
      return;
      }
    line(label.line1,cy-textGap/2);
    line(label.line2,cy+th+textGap/2);
    };

  for(size_t i=0; i<std::size(left); ++i) {
    const Row& r   = left[i];
    const int  cy  = leftCy[i];
    const int  axp = imgX + int(r.ax*float(dw));
    const int  ayp = imgY + int(r.ay*float(dh));
    int gx = imgX - gap - s;               // rightmost glyph next to the art
    glyph(r.ng==2 ? r.g2 : r.g1, gx, cy-s/2);
    if(r.ng==2) {
      gx -= s + tokGap/2;
      glyph(r.g1, gx, cy-s/2);
      }
    drawLabel(leftLabels[i],gx-gap,cy,true);
    hline(imgX-gap+2, axp, cy);
    vline(axp, cy, ayp);
    dot(axp,ayp);
    }

  for(size_t i=0; i<std::size(right); ++i) {
    const Row& r   = right[i];
    const int  cy  = rightCy[i];
    const int  axp = imgX + int(r.ax*float(dw));
    const int  ayp = imgY + int(r.ay*float(dh));
    const int  gx  = imgX + dw + gap;
    glyph(r.g1, gx, cy-s/2);
    drawLabel(rightLabels[i],gx+s+gap,cy,false);
    hline(axp, imgX+dw+gap-2, cy);
    vline(axp, cy, ayp);
    dot(axp,ayp);
    }

  // View / Menu sit in the middle of the pad: label them from above with a
  // straight drop, Gothic-Classic style.
  auto topLbl = [&](PadGlyph::Btn b, const char* txt, bool textOnLeft,
                    float ax, float ay) {
    const int axp = imgX + int(ax*float(dw));
    const int ayp = imgY + int(ay*float(dh));
    const int gx  = axp - s/2;
    glyph(b, gx, topBandY);
    if(textOnLeft)
      fnt.drawText(p, gx-gap-fnt.textSize(txt).w, topBandY+(s+th)/2, txt);
    else
      fnt.drawText(p, gx+s+gap, topBandY+(s+th)/2, txt);
    vline(axp, topBandY+s+2, ayp);
    dot(axp,ayp);
    };
  topLbl(PadGlyph::View, L.inventory, true,  0.433f,0.438f);
  topLbl(PadGlyph::Menu, L.gameMenu,  false, 0.571f,0.433f);

  // Footer: each combo owns a bounded column and wraps its description just
  // like a side callout, so long translations cannot cross the panel edge.
  const int plusW = fnt.textSize("+").w;
  const int comboPrefixW = 2*s+plusW+3*tokGap;
  auto combo = [&](PadGlyph::Btn b1, PadGlyph::Btn b2, const char* text,
                   int x0, int x1, int cy) {
    const int blockW = std::max(1,x1-x0);
    const auto label = wrapLabel(fnt,text,std::max(1,blockW-comboPrefixW));
    const int labelW = std::max(fnt.textSize(label.line1).w,
                                fnt.textSize(label.line2).w);
    int x = x0+std::max(0,(blockW-comboPrefixW-labelW)/2);
    glyph(b1,x,cy-s/2);
    x += s+tokGap;
    fnt.drawText(p,x,cy+th/2,"+");
    x += plusW+tokGap;
    glyph(b2,x,cy-s/2);
    x += s+tokGap;
    drawLabel(label,x,cy,false);
    };

  const int groupGap = std::max(tokGap,int(42.f*scale));
  combo(PadGlyph::LB,PadGlyph::Menu,L.quickSave,
        margin,w/2-groupGap/2,cy1);
  combo(PadGlyph::LB,PadGlyph::View,L.quickLoad,
        w/2+(groupGap-groupGap/2),w-margin,cy1);

  char buf[192] = {};
  std::snprintf(buf,sizeof(buf),"(%s)  %s",L.hold,L.unstuck);
  combo(PadGlyph::L3,PadGlyph::R3,buf,margin,w-margin,cy2);
  }
