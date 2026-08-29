# OpenGothic RendererIOS / Metal

This repository is the development line for a native **iOS/Metal renderer** for
[OpenGothic](https://github.com/Try/OpenGothic). It is focused on renderer
architecture, GPU correctness, iOS lifecycle integration, and repeatable
validation on physical Apple devices.

> [!IMPORTANT]
> This repository is an experimental renderer project, not the recommended
> version for playing the game. For the working iOS port, installation guide,
> and downloadable builds, use **[tryk016/opengothic-ios](https://github.com/tryk016/opengothic-ios)**.

## Project status

RendererIOS is under active development. The current work incrementally moves
rendering paths from the compatibility backend to native Metal while preserving
visual output, save data, resources, and device stability.

The project currently concentrates on:

- native Metal scene extraction and GPU scene submission;
- explicit material and pipeline-state handling;
- shader ABI and render-pass validation;
- iOS scene lifecycle and display pacing;
- deterministic host, simulator, CI, and physical-device evidence;
- fail-closed device testing with cleanup and battery safeguards.

Individual rendering paths are enabled only after their host, CI, and physical
device gates pass. As a result, this branch may intentionally contain partial
verticals, diagnostic code, or temporarily disabled paths while validation is
in progress.

## Who should use this repository?

Use this repository if you want to work on or review the RendererIOS/Metal
backend itself. If you want to install and play OpenGothic on an iPhone or iPad,
go to the player-facing repository instead:

### [Open the working iOS version →](https://github.com/tryk016/opengothic-ios)

## Building for development

You need macOS with a current Xcode toolchain and legally owned *Gothic II:
Night of the Raven* game data. This repository does not include game assets or
scripts.

The iOS build support lives under [`ios/`](ios/). Renderer work is validated in
small, bounded checkpoints; a successful compilation alone is not treated as
proof that a rendering path is ready for players.

## Relationship to other projects

- [Try/OpenGothic](https://github.com/Try/OpenGothic) is the upstream engine.
- [Try/Tempest](https://github.com/Try/Tempest) provides the rendering framework
  used by OpenGothic.
- [tryk016/opengothic-ios](https://github.com/tryk016/opengothic-ios) is the
  working, player-facing iOS port.
- This repository is the dedicated native RendererIOS/Metal development line.

Upstream changes are integrated deliberately so renderer validation remains
reproducible. RendererIOS changes are kept separate from the working port until
they are ready to be adopted.

## Credits and license

The engine is the work of [Try](https://github.com/Try) and the OpenGothic
contributors. This fork builds on OpenGothic and Tempest and is not affiliated
with or endorsed by the original game authors or publishers.

Distributed under the same [license](LICENSE) as the upstream project.
