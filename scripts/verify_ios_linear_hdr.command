#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CORE_SOURCES=(
  game/graphics/iosframeplan.cpp
  game/graphics/ioslinearhdr.cpp
  ios/tests/ioslinearhdr.cpp
)

cd "$REPO"

printf '\n### P2.1e0 linear-HDR value/lifetime contracts\n'
xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr"
"$RUNNER_TEMP/ioslinearhdr"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=address -fno-omit-frame-pointer \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr-asan"
ASAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdr-asan"

xcrun clang++ -std=c++20 \
  -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror \
  -fsanitize=undefined -fno-sanitize-recover=undefined \
  -fno-omit-frame-pointer \
  -Igame "${CORE_SOURCES[@]}" \
  -o "$RUNNER_TEMP/ioslinearhdr-ubsan"
UBSAN_OPTIONS=halt_on_error=1 "$RUNNER_TEMP/ioslinearhdr-ubsan"

printf '\n### P2.1e0 strict native tone-resolve bridge\n'
xcrun clang++ -x objective-c++ -std=c++20 \
  -target arm64-apple-ios16.4 \
  -isysroot "$IOS_SDK" \
  -Wall -Wextra -Wconversion -Wsign-conversion -Werror \
  -Igame \
  -isystem lib/Tempest/Engine/include \
  -isystem lib/ZenKit/include \
  -fsyntax-only game/graphics/ioslinearhdrmetal.mm

printf '\n### P2.1e0 production integration and mutation oracle\n'
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path


def sanitize_cpp(source: str) -> str:
    """Blank comments while preserving code, strings and source offsets."""
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == '"':
                state = "string"
            elif current == "'":
                state = "character"
            elif current == "/" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "line-comment"
            elif current == "/" and following == "*":
                result[index] = result[index + 1] = " "
                index += 1
                state = "block-comment"
        elif state == "string":
            if current == "\\":
                index += 1
            elif current == '"':
                state = "code"
        elif state == "character":
            if current == "\\":
                index += 1
            elif current == "'":
                state = "code"
        elif state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            if current == "*" and following == "/":
                result[index] = result[index + 1] = " "
                index += 1
                state = "code"
            elif current != "\n":
                result[index] = " "
        index += 1
    if state == "block-comment":
        raise ValueError("unterminated block comment")
    return "".join(result)


def compact(source: str) -> str:
    return "".join(sanitize_cpp(source).split())


def function_scope(source: str, signature: str) -> str:
    sanitized = sanitize_cpp(source)
    start = sanitized.find(signature)
    if start < 0 or sanitized.find(signature, start + 1) >= 0:
        raise ValueError(f"function signature is not exact: {signature}")
    brace = sanitized.find("{", start + len(signature))
    if brace < 0:
        raise ValueError(f"function body missing: {signature}")
    depth = 0
    for index in range(brace, len(sanitized)):
        if sanitized[index] == "{":
            depth += 1
        elif sanitized[index] == "}":
            depth -= 1
            if depth == 0:
                return sanitized[start:index + 1]
    raise ValueError(f"function body unterminated: {signature}")


def require_once(source: str, literal: str, label: str) -> int:
    count = source.count(literal)
    if count != 1:
        raise ValueError(f"{label} count changed: {count}")
    return source.index(literal)


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"mutation anchor count changed: {old!r}")
    return source.replace(old, new, 1)


def validate(renderer: str, context: str, native: str) -> None:
    renderer_code = compact(renderer)
    context_code = compact(context)
    settings_call = (
        'context.updateLinearHDRSettings('
        'Gothic::settingsGetF("VIDEO","zVidBrightness"),'
        'Gothic::settingsGetF("VIDEO","zVidContrast"),'
        'Gothic::settingsGetF("VIDEO","zVidGamma"));'
    )
    constructor_order = (
        "Gothic::inst().onSettingsChanged.bind(this,&Impl::setupSettings);",
        "setupSettings();",
    )
    positions = [require_once(renderer_code, value, value)
                 for value in constructor_order]
    if positions != sorted(positions):
        raise ValueError("settings bind/initial refresh order changed")
    require_once(
        renderer_code,
        "Gothic::inst().onSettingsChanged.ubind(this,&Impl::setupSettings);",
        "settings unbind",
    )
    require_once(renderer_code, settings_call, "atomic settings triplet")

    submit = compact(function_scope(
        context,
        "IOSMetalContext::SubmitResult IOSMetalContext::submitFrame("))
    ordered = (
        "constboollinearHDRSceneActive=sceneVisible&&",
        "encoder.setFramebuffer({{impl->linearHDRTargets.color,"
        "Tempest::Vec4(0.f),Tempest::Preserve}},"
        "{impl->linearHDRTargets.depth,1.f,Tempest::Discard});",
        "impl->gpuScene->encode(",
        "constIOSToneResolveConstantsconstants={tone.brightness,"
        "tone.contrast,tone.gamma,tone.exposure,};",
        "encoder.setFramebuffer({});"
        "advanceLinearHDR(IOSLinearHDRFrameEvent::SceneHDR);",
        "encoder.setFramebuffer({{drawable,Tempest::Discard,"
        "Tempest::Preserve}});",
        "impl->linearHDRMetal->encodeToneResolve(",
        "encoder.setFramebuffer({});"
        "advanceLinearHDR(IOSLinearHDRFrameEvent::ToneResolve);",
        'encoder.setDebugMarker("RendererIOSUIovertoneresolve");'
        "encoder.setFramebuffer({{drawable,Tempest::Preserve,"
        "Tempest::Preserve}});",
        "advanceLinearHDR(IOSLinearHDRFrameEvent::LdrOverlay,true);",
        "frameContext.uiMesh.draw(encoder);",
        "impl->device.submit(command);",
        "impl->device.present(impl->swapchain);",
        "IOSLinearHDRFrameEvent::Present,",
    )
    positions = [require_once(submit, value, value) for value in ordered]
    if positions != sorted(positions):
        raise ValueError("scene/resolve/overlay/present order changed")
    if submit.count("impl->gpuScene->encode(") != 1:
        raise ValueError("native scene encode count changed")
    if submit.count("impl->linearHDRMetal->encodeToneResolve(") != 1:
        raise ValueError("tone resolve encode count changed")
    if submit.count("frameContext.uiMesh.draw(encoder);") != 1:
        raise ValueError("2D UI draw count changed")

    if context_code.count("iosLinearHDRCommitProvenEvidence(") != 2:
        raise ValueError("OFF/ON Proven commit coverage changed")
    if context_code.count("markLinearHDRTerminalFailed(frame);") != 2:
        raise ValueError("terminal failure publication coverage changed")
    begin_frame = compact(function_scope(
        context,
        "std::optional<IOSMetalContext::FrameLease> "
        "IOSMetalContext::beginFrame()"))
    begin_order = (
        "frameContext.fence.wait(0)",
        "impl->materializeLinearHDREvidenceAfterTerminal(frameContext)",
    )
    begin_positions = [require_once(begin_frame, value, value)
                       for value in begin_order]
    if begin_positions != sorted(begin_positions):
        raise ValueError("frame fence/evidence order changed")
    settle = compact(function_scope(
        context,
        "bool settleGpu(SettleReason reason, const char* operation,"))
    settle_order = (
        "frame.fence.wait(0)",
        "materializeLinearHDREvidenceAfterTerminal(frame)",
        'pollPresentFailure("RendererIOSasynchronousMetalpresentfailed")',
    )
    settle_positions = [require_once(settle, value, value)
                        for value in settle_order]
    if settle_positions != sorted(settle_positions):
        raise ValueError("lifecycle fence/evidence/mailbox order changed")
    materialize = compact(function_scope(
        context,
        "bool materializeLinearHDREvidenceAfterTerminal("))
    diagnostic_wait = require_once(
        materialize,
        "if(!deviceAlreadyIdle){try{device.waitIdle();}",
        "diagnostic terminal waitIdle",
    )
    diagnostic_mailbox = require_once(
        materialize,
        'pollPresentFailure("RendererIOSlinearHDRterminalpresentfailed")',
        "diagnostic terminal mailbox",
    )
    diagnostic_commit = materialize.rfind(
        "iosLinearHDRCommitProvenEvidence(")
    marker = require_once(
        materialize,
        'Log::i("RendererIOSlinearHDR:v=1b=",',
        "diagnostic terminal marker",
    )
    if not (diagnostic_wait < diagnostic_mailbox < diagnostic_commit < marker):
        raise ValueError("diagnostic wait/mailbox/Proven/marker order changed")

    native_code = compact(native)
    if native_code.count("@try{") != 2 or \
       native_code.count("@catch(NSException*exception)") != 2:
        raise ValueError("probe and pipeline Objective-C exception scopes merged")
    native_order = (
        "descriptor.usage=MTLTextureUsageRenderTarget|"
        "MTLTextureUsageShaderRead;",
        "[devicenewTextureWithDescriptor:descriptor];",
        "probeResult=IOSLinearHDRProbeResult::success();",
        "[texturerelease];",
        "[devicenewLibraryWithURL:libraryUrlerror:&libraryError]",
    )
    native_positions = [require_once(native_code, value, value)
                        for value in native_order]
    if native_positions != sorted(native_positions):
        raise ValueError("one-shot probe lifetime/order changed")
    for required in (
        "for(id<MTLBinding>bindinginreflection.vertexBindings){"
        "if(binding.used)returnfalse;}",
        "if(binding.index!=NSUInteger(0u)||!binding.argument)returnfalse;",
        "descriptor.colorAttachments[0].pixelFormat="
        "MTLPixelFormatBGRA8Unorm;",
        "descriptor.colorAttachments[0].blendingEnabled=NO;",
        "descriptor.depthAttachmentPixelFormat=MTLPixelFormatInvalid;",
        "descriptor.rasterSampleCount=1u;",
        "Tempest::MetalApi::withActiveRenderEncoder(",
    ):
        require_once(native_code, required, required)
    for forbidden in (
        "newLibraryWithSource",
        "MTLCompileOptions",
        "newCommandQueue",
        "commandBufferWith",
        "presentDrawable",
    ):
        if forbidden in native_code:
            raise ValueError(f"native bridge owns forbidden operation: {forbidden}")


renderer_path = Path("game/graphics/rendererios.cpp")
context_path = Path("game/graphics/iosmetalcontext.cpp")
native_path = Path("game/graphics/ioslinearhdrmetal.mm")
renderer = renderer_path.read_text()
context = context_path.read_text()
native = native_path.read_text()
validate(renderer, context, native)

mutations = []
mutations.append((
    "missing-initial-settings-refresh",
    replace_once(renderer, "    setupSettings();\n", "    (void)0;\n"),
    context,
    native,
))
mutations.append((
    "partial-settings-triplet",
    replace_once(
        renderer,
        'Gothic::settingsGetF("VIDEO","zVidGamma")',
        'Gothic::settingsGetF("VIDEO","zVidContrast")'),
    context,
    native,
))
mutations.append((
    "missing-settings-unbind",
    replace_once(renderer, ".onSettingsChanged.ubind(",
                 ".onSettingsChanged.bind("),
    context,
    native,
))
mutations.append((
    "direct-drawable-scene",
    renderer,
    replace_once(
        context,
        "{{impl->linearHDRTargets.color,Tempest::Vec4(0.f),Tempest::Preserve}},",
        "{{drawable,Tempest::Vec4(0.f),Tempest::Preserve}},"),
    native,
))
ui_draw = "      frameContext.uiMesh.draw(encoder);\n"
tone_event = (
    "        advanceLinearHDR(IOSLinearHDRFrameEvent::ToneResolve);\n"
)
ui_before_resolve = replace_once(context, ui_draw, "")
ui_before_resolve = replace_once(
    ui_before_resolve, tone_event, ui_draw + tone_event)
mutations.append((
    "ui-before-resolve",
    renderer,
    ui_before_resolve,
    native,
))

killed = 0
for name, mutated_renderer, mutated_context, mutated_native in mutations:
    try:
        validate(mutated_renderer, mutated_context, mutated_native)
    except ValueError:
        killed += 1
    else:
        raise SystemExit(f"P2.1e0 mutation survived: {name}")
if killed != len(mutations):
    raise SystemExit("P2.1e0 mutation count changed")

# A comment must never satisfy an active-code source contract.
comment_only = renderer.replace(
    "    setupSettings();\n",
    "    // setupSettings();\n",
    1,
)
try:
    validate(comment_only, context, native)
except ValueError:
    pass
else:
    raise SystemExit("P2.1e0 comment-only settings mutation survived")

print(f"RendererIOS linear-HDR integration mutations killed: {killed + 1}")
PY
