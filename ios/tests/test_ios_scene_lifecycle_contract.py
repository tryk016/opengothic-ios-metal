#!/usr/bin/env python3
"""Fail-closed source contract for the iOS scene-based application lifecycle."""

from __future__ import annotations

import copy
import os
from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[2]
TEMPEST_ROOT = Path(os.environ.get("TEMPEST_ROOT", ROOT / "lib/Tempest"))
SOURCE = TEMPEST_ROOT / "Engine/system/api/iosapi.mm"
PLIST = ROOT / "Info.plist.in"
PLACEHOLDER = "${OPENGOTHIC_RENDERER_IOS_METAL_CAPTURE_PLIST_ENTRY}"

SOURCE_ANCHORS = (
    "@interface TempestSceneDelegate : UIResponder <UIWindowSceneDelegate>",
    "willConnectToSession:(UISceneSession*)session",
    "initWithWindowScene:windowScene",
    "window.frame = windowScene.coordinateSpace.bounds;",
    "window.contentScaleFactor = windowScene.screen.scale;",
    "self.window = window;",
    "mainWindow = window;",
    "[window makeKeyAndVisible];",
    "- (void)sceneWillResignActive:(UIScene*)scene",
    "- (void)sceneDidEnterBackground:(UIScene*)scene",
    "- (void)sceneWillEnterForeground:(UIScene*)scene",
    "- (void)sceneDidBecomeActive:(UIScene*)scene",
    "configurationForConnectingSceneSession:(UISceneSession*)session",
    "configuration.delegateClass = TempestSceneDelegate.class;",
)

LEGACY_LIFECYCLE = (
    "applicationWillResignActive:",
    "applicationDidEnterBackground:",
    "applicationWillEnterForeground:",
    "applicationDidBecomeActive:",
    "initWithFrame: frame",
)


def decode_plist(source: str) -> dict[str, object]:
    if source.count(PLACEHOLDER) != 1:
        raise ValueError("capture plist placeholder cardinality differs")
    return plistlib.loads(source.replace(PLACEHOLDER, "").encode("utf-8"))


def validate_source(source: str) -> None:
    for anchor in SOURCE_ANCHORS:
        if source.count(anchor) != 1:
            raise ValueError(f"scene lifecycle anchor differs: {anchor}")
    for forbidden in LEGACY_LIFECYCLE:
        if forbidden in source:
            raise ValueError(f"legacy application lifecycle remains: {forbidden}")

    scene_begin = source.index("@implementation TempestSceneDelegate")
    scene_end = source.index("@end", scene_begin)
    app_begin = source.index("@implementation AppDelegate", scene_end)
    app_end = source.index("@end", app_begin)
    scene_scope = source[scene_begin:scene_end]
    app_scope = source[app_begin:app_end]

    ordered = (
        "initWithWindowScene:windowScene",
        "self.window = window;",
        "mainWindow = window;",
        "[window makeKeyAndVisible];",
    )
    positions = [scene_scope.index(anchor) for anchor in ordered]
    if positions != sorted(positions) or len(set(positions)) != len(positions):
        raise ValueError("scene window publication order differs")
    if "TempestWindow" in app_scope or "makeKeyAndVisible" in app_scope:
        raise ValueError("AppDelegate still creates the application window")
    if app_scope.index("configurationForConnectingSceneSession") > app_scope.index(
        "configuration.delegateClass = TempestSceneDelegate.class;"
    ):
        raise ValueError("scene configuration order differs")


def validate_plist(document: dict[str, object]) -> None:
    manifest = document.get("UIApplicationSceneManifest")
    if not isinstance(manifest, dict) or set(manifest) != {
        "UIApplicationSupportsMultipleScenes",
        "UISceneConfigurations",
    }:
        raise ValueError("scene manifest keys differ")
    if manifest["UIApplicationSupportsMultipleScenes"] is not False:
        raise ValueError("multiple scenes must remain disabled")
    configurations = manifest["UISceneConfigurations"]
    if not isinstance(configurations, dict) or set(configurations) != {
        "UIWindowSceneSessionRoleApplication"
    }:
        raise ValueError("window-scene role differs")
    entries = configurations["UIWindowSceneSessionRoleApplication"]
    if not isinstance(entries, list) or len(entries) != 1:
        raise ValueError("window-scene configuration count differs")
    entry = entries[0]
    if not isinstance(entry, dict) or entry != {
        "UISceneConfigurationName": "Default Configuration",
        "UISceneDelegateClassName": "TempestSceneDelegate",
    }:
        raise ValueError("window-scene configuration differs")


def rejected(function, value: object, label: str) -> None:
    try:
        function(value)
    except (KeyError, TypeError, ValueError):
        return
    raise AssertionError(f"mutation survived: {label}")


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    plist_source = PLIST.read_text(encoding="utf-8")
    document = decode_plist(plist_source)
    validate_source(source)
    validate_plist(document)

    mutations = 0
    for anchor in SOURCE_ANCHORS:
        rejected(validate_source, source.replace(anchor, "", 1), f"removed {anchor}")
        mutations += 1
    for forbidden in LEGACY_LIFECYCLE:
        rejected(validate_source, source + "\n" + forbidden + "\n", f"restored {forbidden}")
        mutations += 1
    rejected(
        validate_source,
        source.replace(
            "self.window = window;\n  mainWindow = window;",
            "mainWindow = window;\n  self.window = window;",
            1,
        ),
        "window publication reordered",
    )
    mutations += 1

    missing_manifest = copy.deepcopy(document)
    del missing_manifest["UIApplicationSceneManifest"]
    rejected(validate_plist, missing_manifest, "missing scene manifest")
    mutations += 1
    multiple = copy.deepcopy(document)
    multiple["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] = True
    rejected(validate_plist, multiple, "multiple scenes enabled")
    mutations += 1
    wrong_delegate = copy.deepcopy(document)
    wrong_delegate["UIApplicationSceneManifest"]["UISceneConfigurations"][
        "UIWindowSceneSessionRoleApplication"
    ][0]["UISceneDelegateClassName"] = "AppDelegate"
    rejected(validate_plist, wrong_delegate, "wrong scene delegate")
    mutations += 1
    extra_configuration = copy.deepcopy(document)
    extra_configuration["UIApplicationSceneManifest"]["UISceneConfigurations"][
        "UIWindowSceneSessionRoleApplication"
    ].append(copy.deepcopy(
        extra_configuration["UIApplicationSceneManifest"]["UISceneConfigurations"][
            "UIWindowSceneSessionRoleApplication"
        ][0]
    ))
    rejected(validate_plist, extra_configuration, "extra scene configuration")
    mutations += 1

    print(f"iOS scene lifecycle contract: PASS mutations-killed={mutations}")


if __name__ == "__main__":
    main()
