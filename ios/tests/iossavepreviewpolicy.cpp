#include "graphics/iossavepreviewpolicy.h"

#include <cassert>
#include <cstdint>
#include <type_traits>

int main() {
  static_assert(std::is_enum_v<IOSSavePreviewRoute>);
  static_assert(IOSSavePreviewPlaceholderWidth==4u);
  static_assert(IOSSavePreviewPlaceholderHeight==4u);
  static_assert(IOSSavePreviewPlaceholderWidth*
                IOSSavePreviewPlaceholderHeight==16u);
  static_assert(!iosSavePreviewNeedsGpuCapture(false,0u));
  static_assert(!iosSavePreviewNeedsGpuCapture(false,1u));
  static_assert(!iosSavePreviewNeedsGpuCapture(false,2u));
  static_assert(!iosSavePreviewNeedsGpuCapture(false,3u));
  static_assert(!iosSavePreviewNeedsGpuCapture(false,8u));

  static_assert(!iosSavePreviewNeedsGpuCapture(true,0u));
  static_assert( iosSavePreviewNeedsGpuCapture(true,1u));
  static_assert( iosSavePreviewNeedsGpuCapture(true,2u));
  static_assert( iosSavePreviewNeedsGpuCapture(true,3u));
  static_assert(!iosSavePreviewNeedsGpuCapture(true,4u));
  static_assert(!iosSavePreviewNeedsGpuCapture(true,5u));
  static_assert(!iosSavePreviewNeedsGpuCapture(true,6u));
  static_assert(!iosSavePreviewNeedsGpuCapture(true,7u));
  static_assert(!iosSavePreviewNeedsGpuCapture(true,8u));

  for(uint32_t fault=0u; fault<=8u; ++fault) {
    const bool expected = fault>=1u && fault<=3u;
    assert(iosSavePreviewNeedsGpuCapture(true,fault)==expected);
    assert(!iosSavePreviewNeedsGpuCapture(false,fault));
    }

  assert(iosSavePreviewRoute(true,9u)==
         IOSSavePreviewRoute::CpuPlaceholder);
  return 0;
  }
