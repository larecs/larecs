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
        _larecs_developer_dir="$(xcode-select -p 2>/dev/null)"
        _larecs_best_sdk=""
        _larecs_best_name=""
        for _larecs_sdk in \
            /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk \
            "$_larecs_developer_dir"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk; do
            if [ -d "$_larecs_sdk" ] && _larecs_sdk_is_linkable "$_larecs_sdk"; then
                _larecs_name="${_larecs_sdk##*/}"
                if [ -z "$_larecs_best_sdk" ] || \
                    [ "$(printf '%s\n%s\n' "$_larecs_best_name" "$_larecs_name" | sort -V | tail -n 1)" = "$_larecs_name" ]; then
                    _larecs_best_sdk="$_larecs_sdk"
                    _larecs_best_name="$_larecs_name"
                fi
            fi
        done
        if [ -n "$_larecs_best_sdk" ]; then
            export SDKROOT="$_larecs_best_sdk"
        fi
    fi
    unset _larecs_default_sdk _larecs_developer_dir _larecs_sdk _larecs_name _larecs_best_sdk _larecs_best_name
fi

unset -f _larecs_sdk_is_linkable
