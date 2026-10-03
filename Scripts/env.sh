# Sourced by the build and test scripts.
#
# Use a full Xcode when one is installed: SwiftUI's and Testing's macros then work out of the box.
# Without it (Command Line Tools only) the default macOS 27 SDK needs Xcode's SwiftUI macro plugin,
# so the build falls back to the macOS 26 SDK that ships with the tools. This never changes the
# system-wide `xcode-select` setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SDK_ARGS=()
DEV_DIR="$(xcode-select -p)"
if [[ "$DEV_DIR" == "/Library/Developer/CommandLineTools" && -d "$DEV_DIR/SDKs/MacOSX26.sdk" ]]; then
    SDK_ARGS=(--sdk "$DEV_DIR/SDKs/MacOSX26.sdk")
fi
