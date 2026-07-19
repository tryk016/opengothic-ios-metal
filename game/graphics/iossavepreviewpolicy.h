#pragma once

#include <cstdint>

enum class IOSSavePreviewRoute : uint8_t {
  CpuPlaceholder,
  GpuDiagnosticCapture,
  };

inline constexpr uint32_t IOSSavePreviewPlaceholderWidth  = 4u;
inline constexpr uint32_t IOSSavePreviewPlaceholderHeight = 4u;

// RendererIOS does not yet compose a real save thumbnail. The product path
// therefore uses a tiny CPU placeholder instead of allocating, clearing and
// synchronously reading back a black GPU attachment. The three preview-specific
// fault builds keep the old GPU route so their lifecycle contracts remain
// executable until a real preview pass replaces this transitional policy.
constexpr IOSSavePreviewRoute iosSavePreviewRoute(
    bool diagnosticsEnabled, uint32_t faultModeId) noexcept {
  if(!diagnosticsEnabled)
    return IOSSavePreviewRoute::CpuPlaceholder;
  if(faultModeId>=1u && faultModeId<=3u)
    return IOSSavePreviewRoute::GpuDiagnosticCapture;
  return IOSSavePreviewRoute::CpuPlaceholder;
  }

constexpr bool iosSavePreviewNeedsGpuCapture(
    bool diagnosticsEnabled, uint32_t faultModeId) noexcept {
  return iosSavePreviewRoute(diagnosticsEnabled,faultModeId)==
         IOSSavePreviewRoute::GpuDiagnosticCapture;
  }
