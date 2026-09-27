# activate_macos_sdk.sh — pixi activation script (osx-arm64 only).
#
# Points SDKROOT at a macOS SDK whose libSystem.tbd can be linked by the
# conda-forge ld64 that `mojo build` uses.
#
# Newer SDKs (e.g. MacOSX27.0.sdk) list the `arm64e.x1` architecture in their
# .tbd stubs. ld64 rejects those files ("malformed file ... unknown
# architecture"), so every libc symbol (_write, _strlen, ...) ends up undefined
# at link time. If the default SDK is affected, we pick the newest installed
# SDK that does not use that architecture.
#
# An SDKROOT that is already set is left untouched.

_larecs_sdk_is_linkable() {
    [ -f "$1/usr/lib/libSystem.tbd" ] && ! grep -q "arm64e\.x1" "$1/usr/lib/libSystem.tbd"
}

if [ -z "${SDKROOT:-}" ]; then
    _larecs_default_sdk="$(xcrun --show-sdk-path 2>/dev/null)"
    if [ -n "$_larecs_default_sdk" ] && ! _larecs_sdk_is_linkable "$_larecs_default_sdk"; then
        # Newest SDK first, ordered by the version in the directory name.
        for _larecs_sdk in $(ls -d \
            /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk \
            "$(xcode-select -p 2>/dev/null)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk \
            2>/dev/null | awk -F/ '{ print $NF "\t" $0 }' | sort -V -r | cut -f 2); do
            if _larecs_sdk_is_linkable "$_larecs_sdk"; then
                export SDKROOT="$_larecs_sdk"
                break
            fi
        done
    fi
    unset _larecs_default_sdk _larecs_sdk
fi

unset -f _larecs_sdk_is_linkable
