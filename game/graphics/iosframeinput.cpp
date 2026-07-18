#include "iosframeinput.h"

#include <type_traits>

IOSUIPacket::IOSUIPacket(uint64_t serial) noexcept
  : transportSerial(serial) {
  }

IOSUIPacket::IOSUIPacket(IOSUIPacket&& other) noexcept
  : transportSerial(std::exchange(other.transportSerial,0)) {
  }

IOSUIPacket& IOSUIPacket::operator=(IOSUIPacket&& other) noexcept {
  if(this!=&other)
    transportSerial = std::exchange(other.transportSerial,0);
  return *this;
  }

IOSVideoPacket::IOSVideoPacket(uint64_t serial) noexcept
  : transportSerial(serial) {
  }

IOSVideoPacket::IOSVideoPacket(IOSVideoPacket&& other) noexcept
  : transportSerial(std::exchange(other.transportSerial,0)) {
  }

IOSVideoPacket& IOSVideoPacket::operator=(IOSVideoPacket&& other) noexcept {
  if(this!=&other)
    transportSerial = std::exchange(other.transportSerial,0);
  return *this;
  }

IOSFrameInput::IOSFrameInput(IOSSceneSnapshotPtr snapshot,
                             IOSUIPacket&& ui,
                             IOSVideoPacket&& video,
                             IOSCaptureRequest capture) noexcept
  : snapshot(std::move(snapshot)),
    ui(std::move(ui)),
    video(std::move(video)),
    capture(capture) {
  }

static_assert(!std::is_copy_constructible_v<IOSUIPacket>);
static_assert(std::is_nothrow_move_constructible_v<IOSUIPacket>);
static_assert(std::is_nothrow_move_assignable_v<IOSUIPacket>);
static_assert(!std::is_copy_constructible_v<IOSVideoPacket>);
static_assert(std::is_nothrow_move_constructible_v<IOSVideoPacket>);
static_assert(std::is_nothrow_move_assignable_v<IOSVideoPacket>);
static_assert(!std::is_copy_constructible_v<IOSFrameInput>);
static_assert(std::is_nothrow_move_constructible_v<IOSFrameInput>);
static_assert(std::is_nothrow_move_assignable_v<IOSFrameInput>);
