#!/bin/sh
# Checks a bundle built by `make app` without launching it:
#   - Info.plist is valid and has the keys the app and Finder rely on;
#   - the executable it names is there and is a Mach-O binary;
#   - the icon it names is there;
#   - PkgInfo says APPL;
#   - the bundle carries a valid ad-hoc signature (`codesign -dv` reports Signature=adhoc).
# Usage: Packaging/check-app.sh [build/FS2.app]
set -eu

app=${1:-build/FS2.app}
plist="$app/Contents/Info.plist"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null
}

[ -d "$app" ] || { echo "FAIL: no bundle at $app (run make app)" >&2; exit 1; }
plutil -lint -s "$plist" || fail "Info.plist is not a valid property list"

for key in CFBundleExecutable CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundlePackageType \
    CFBundleShortVersionString CFBundleVersion CFBundleIconFile LSMinimumSystemVersion \
    NSHumanReadableCopyright NSPrincipalClass NSHighResolutionCapable; do
    if v=$(value "$key"); then
        echo "  $key = $v"
    else
        fail "Info.plist has no $key"
    fi
done
[ "$(value CFBundlePackageType)" = APPL ] || fail "CFBundlePackageType is not APPL"
[ "$(value LSMinimumSystemVersion)" = 15.0 ] || fail "LSMinimumSystemVersion is not 15.0"

exe="$app/Contents/MacOS/$(value CFBundleExecutable)"
if [ -x "$exe" ] && file "$exe" | grep -q 'Mach-O'; then
    echo "  executable: $(file -b "$exe")"
else
    fail "no Mach-O executable at $exe"
fi

icon="$app/Contents/Resources/$(value CFBundleIconFile).icns"
if [ -s "$icon" ]; then
    echo "  icon: $icon ($(wc -c < "$icon" | tr -d ' ') bytes)"
else
    fail "no icon at $icon"
fi

[ "$(cat "$app/Contents/PkgInfo" 2>/dev/null)" = 'APPL????' ] || fail "PkgInfo is not APPL????"

signature=$(codesign -dv "$app" 2>&1) || fail "codesign -dv failed: $signature"
echo "$signature" | sed 's/^/  /'
echo "$signature" | grep -q '^Signature=adhoc' || fail "the signature is not ad-hoc"
codesign --verify --strict "$app" || fail "codesign --verify failed"

if [ "$failures" -ne 0 ]; then
    echo "$app: $failures check(s) failed" >&2
    exit 1
fi
echo "$app: OK"
