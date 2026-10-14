#!/usr/bin/env bash
set -euo pipefail

clipped_test_source="$(cd "$(dirname "$0")/.." && pwd)"
clipped_test_temp=$(mktemp -d "${TMPDIR:-/tmp}/clipped-paths.XXXXXX")
trap 'rm -rf "$clipped_test_temp"' EXIT
clipped_test_project="$clipped_test_temp/project with spaces"
export CLIPPED_PATH_TEST_OUTPUT="$clipped_test_temp/build products"
export CLIPPED_PATH_TEST_LAUNCH="$clipped_test_temp/launch"
export CLIPPED_PATH_TEST_CONFIGURATION=Debug
export CLIPPED_PATH_TEST_PROJECT=Clipped/Clipped.xcodeproj
export CLIPPED_PATH_TEST_SCHEME=Clipped
export CLIPPED_PATH_TEST_MODE=''
export CLIPPED_PATH_TEST_LOOKUPS="$clipped_test_temp/lookups"
export CLIPPED_PATH_TEST_DITTO
CLIPPED_PATH_TEST_DITTO=$(command -v ditto)
export CLIPPED_PATH_TEST_SHASUM
CLIPPED_PATH_TEST_SHASUM=$(command -v shasum)
export CLIPPED_PATH_TEST_MV
CLIPPED_PATH_TEST_MV=$(command -v mv)
export CLIPPED_PATH_TEST_TOOLS="$clipped_test_temp/tools"
mkdir -p "$clipped_test_project/scripts" "$clipped_test_temp/bin"
cp "$clipped_test_source/Makefile" "$clipped_test_project/Makefile"
cp "$clipped_test_source/scripts/build-products-dir.sh" "$clipped_test_project/scripts/"

cat > "$clipped_test_temp/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -eu
test "$#" -eq 7
test "$1" = -project
test "$2" = "$CLIPPED_PATH_TEST_PROJECT"
test "$3" = -scheme
test "$4" = "$CLIPPED_PATH_TEST_SCHEME"
test "$5" = -configuration
test "$6" = "$CLIPPED_PATH_TEST_CONFIGURATION"
for argument in "$@"; do
    if [ "$argument" = -showBuildSettings ]; then
        printf 'lookup\n' >> "$CLIPPED_PATH_TEST_LOOKUPS"
        if [ "$CLIPPED_PATH_TEST_MODE" = package-lookup-failure ] && \
            [ "$(wc -l < "$CLIPPED_PATH_TEST_LOOKUPS")" -eq 2 ]; then
            exit 42
        fi
        if [ "$CLIPPED_PATH_TEST_MODE" = settings-failure ]; then
            printf '    BUILT_PRODUCTS_DIR = %s\n' "$CLIPPED_PATH_TEST_OUTPUT"
            exit 42
        fi
        if [ "$CLIPPED_PATH_TEST_MODE" = missing-directory ]; then
            printf '    PRODUCT_NAME = Clipped\n'
            exit 0
        fi
        printf '    OTHER_BUILT_PRODUCTS_DIR = /wrong-prefix\n'
        printf '    BUILT_PRODUCTS_DIR = %s\n' "$CLIPPED_PATH_TEST_OUTPUT"
        printf '    BUILT_PRODUCTS_DIR = /later-target\n'
        awk 'BEGIN { for (i = 0; i < 2000; i++) print "    UNRELATED_SETTING = padding to exercise settings output larger than a pipe buffer" }'
        exit 0
    fi
done
test "$7" = build
if [ "$CLIPPED_PATH_TEST_MODE" = build-failure ]; then
    exit 41
fi
STUB
cat > "$clipped_test_temp/bin/open" <<'STUB'
#!/usr/bin/env bash
set -eu
test "$#" -eq 1
printf '%s\n' "$1" > "$CLIPPED_PATH_TEST_LAUNCH"
STUB
cat > "$clipped_test_temp/bin/security" <<'STUB'
#!/usr/bin/env bash
echo 'Build-path fixtures must not inspect the keychain.' >&2
exit 99
STUB
chmod +x "$clipped_test_temp/bin/xcodebuild" "$clipped_test_temp/bin/open" "$clipped_test_temp/bin/security"
export PATH="$clipped_test_temp/bin:$PATH"
export MAKEFLAGS='DEVELOPER_ID_TEAM= SIGN_ARGS='

make -s -C "$clipped_test_project" run > "$clipped_test_temp/run.log" 2>&1
if [ "$(cat "$CLIPPED_PATH_TEST_LAUNCH")" != "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app" ]; then
    echo 'make run did not pass the complete app path to open.' >&2
    cat "$CLIPPED_PATH_TEST_LAUNCH" >&2
    exit 1
fi
export CLIPPED_PATH_TEST_OUTPUT="$clipped_test_temp/products"
make -s -C "$clipped_test_project" run > "$clipped_test_temp/run.log" 2>&1
test "$(cat "$CLIPPED_PATH_TEST_LAUNCH")" = "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app"
export CLIPPED_PATH_TEST_PROJECT='Custom Project/Clipped.xcodeproj'
export CLIPPED_PATH_TEST_SCHEME='Custom Scheme'
make -s -C "$clipped_test_project" run 'PROJECT_DIR=Custom Project' \
    "SCHEME=$CLIPPED_PATH_TEST_SCHEME" > "$clipped_test_temp/run.log" 2>&1
test "$(cat "$CLIPPED_PATH_TEST_LAUNCH")" = "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app"
export CLIPPED_PATH_TEST_PROJECT=Clipped/Clipped.xcodeproj
export CLIPPED_PATH_TEST_SCHEME=Clipped
for mode in build-failure settings-failure missing-directory; do
    export CLIPPED_PATH_TEST_MODE="$mode"
    for target in run package; do
        export CLIPPED_PATH_TEST_CONFIGURATION=Debug
        if [ "$target" = package ]; then
            export CLIPPED_PATH_TEST_CONFIGURATION=Release
        fi
        rm -f "$CLIPPED_PATH_TEST_LAUNCH"
        if make -s -C "$clipped_test_project" "$target" > "$clipped_test_temp/failure.log" 2>&1; then
            echo "make $target succeeded in the $mode fixture." >&2
            exit 1
        fi
        test ! -e "$CLIPPED_PATH_TEST_LAUNCH"
        test ! -e "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip"
    done
done
export CLIPPED_PATH_TEST_MODE=''
export CLIPPED_PATH_TEST_OUTPUT="$clipped_test_temp/build products"
export CLIPPED_PATH_TEST_CONFIGURATION=Release
mkdir -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources"
printf 'current\n' > "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources/current.txt"
if ! make -s -C "$clipped_test_project" package > "$clipped_test_temp/package.log" 2>&1; then
    cat "$clipped_test_temp/package.log" >&2
    exit 1
fi
test "$(unzip -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" Clipped.app/Contents/Resources/current.txt)" = current
grep -Fx "Built to: $CLIPPED_PATH_TEST_OUTPUT/Clipped.app" "$clipped_test_temp/package.log"
rm "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources/current.txt"
printf 'new\n' > "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources/new.txt"
make -s -C "$clipped_test_project" package > "$clipped_test_temp/package.log" 2>&1
unzip -Z1 "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" > "$clipped_test_temp/entries"
if grep -qx 'Clipped.app/Contents/Resources/current.txt' "$clipped_test_temp/entries"; then
    echo 'Repeated packaging retained a deleted app resource.' >&2
    exit 1
fi
test "$(unzip -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" Clipped.app/Contents/Resources/new.txt)" = new
package_hash=$(shasum -a 256 "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip")
rm "$CLIPPED_PATH_TEST_LOOKUPS"
export CLIPPED_PATH_TEST_MODE=package-lookup-failure
if make -s -C "$clipped_test_project" package > "$clipped_test_temp/failure.log" 2>&1; then
    echo 'Packaging succeeded after its own settings lookup failed.' >&2
    exit 1
fi
test "$(shasum -a 256 "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip")" = "$package_hash"
export CLIPPED_PATH_TEST_MODE=''
export CLIPPED_PATH_TEST_OUTPUT="$clipped_test_temp/products"
mkdir -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources"
printf 'ordinary\n' > "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources/current.txt"
make -s -C "$clipped_test_project" package > "$clipped_test_temp/package.log" 2>&1
test "$(unzip -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" Clipped.app/Contents/Resources/current.txt)" = ordinary
rm "$CLIPPED_PATH_TEST_LOOKUPS"
if bash "$clipped_test_project/scripts/build-products-dir.sh" > "$clipped_test_temp/failure.log" 2>&1; then
    echo 'The settings helper accepted missing arguments.' >&2
    exit 1
fi
test ! -e "$CLIPPED_PATH_TEST_LOOKUPS"
mkdir -p "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/MacOS"
printf 'fixture executable\n' > "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/MacOS/Clipped"
chmod +x "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/MacOS/Clipped"
ln -s current.txt "$CLIPPED_PATH_TEST_OUTPUT/Clipped.app/Contents/Resources/linked.txt"
make -s -C "$clipped_test_project" package > "$clipped_test_temp/package.log" 2>&1
ditto -x -k "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" "$clipped_test_temp/extracted"
test -x "$clipped_test_temp/extracted/Clipped.app/Contents/MacOS/Clipped"
test -L "$clipped_test_temp/extracted/Clipped.app/Contents/Resources/linked.txt"
test "$(readlink "$clipped_test_temp/extracted/Clipped.app/Contents/Resources/linked.txt")" = current.txt
cp "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" "$clipped_test_temp/original.zip"
cat > "$clipped_test_temp/bin/ditto" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'archive\n' >> "$CLIPPED_PATH_TEST_TOOLS"
case "$CLIPPED_PATH_TEST_MODE" in
    archive-failure|corrupt-archive)
        printf 'partial archive\n' > "${!#}"
        if [ "$CLIPPED_PATH_TEST_MODE" = archive-failure ]; then exit 73; fi
        exit 0
        ;;
esac
exec "$CLIPPED_PATH_TEST_DITTO" "$@"
STUB
cat > "$clipped_test_temp/bin/shasum" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'hash\n' >> "$CLIPPED_PATH_TEST_TOOLS"
if [ "$CLIPPED_PATH_TEST_MODE" = hash-failure ]; then
    printf 'partial hash output\n'
    exit 75
fi
exec "$CLIPPED_PATH_TEST_SHASUM" "$@"
STUB
cat > "$clipped_test_temp/bin/mv" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'publish\n' >> "$CLIPPED_PATH_TEST_TOOLS"
if [ "$CLIPPED_PATH_TEST_MODE" = publish-failure ]; then exit 74; fi
exec "$CLIPPED_PATH_TEST_MV" "$@"
STUB
chmod +x "$clipped_test_temp/bin/ditto" "$clipped_test_temp/bin/shasum" "$clipped_test_temp/bin/mv"

assert_no_staging() {
    if [ -n "$(find "$CLIPPED_PATH_TEST_OUTPUT" -name '.clipped-package.*' -print)" ]; then
        echo 'Packaging left temporary archive staging behind.' >&2
        exit 1
    fi
}

for CLIPPED_PATH_TEST_MODE in archive-failure corrupt-archive hash-failure publish-failure \
    build-failure settings-failure missing-directory package-lookup-failure; do
    : > "$CLIPPED_PATH_TEST_LOOKUPS"
    : > "$CLIPPED_PATH_TEST_TOOLS"
    if make -s -C "$clipped_test_project" package > "$clipped_test_temp/failure.log" 2>&1; then
        echo "Packaging succeeded in failure fixture: $CLIPPED_PATH_TEST_MODE" >&2
        exit 1
    fi
    cmp -s "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" "$clipped_test_temp/original.zip"
    if grep -Eq 'Package ready:|SHA256:' "$clipped_test_temp/failure.log"; then
        echo "Packaging failure printed success: $CLIPPED_PATH_TEST_MODE" >&2
        exit 1
    fi
    assert_no_staging
    case "$CLIPPED_PATH_TEST_MODE" in
        build-failure|settings-failure|missing-directory|package-lookup-failure)
            test ! -s "$CLIPPED_PATH_TEST_TOOLS"
            ;;
        archive-failure|corrupt-archive|hash-failure)
            if grep -q publish "$CLIPPED_PATH_TEST_TOOLS"; then
                echo 'Invalid archive reached publication.' >&2
                exit 1
            fi
            ;;
    esac
done
CLIPPED_PATH_TEST_MODE=''
make -s -C "$clipped_test_project" package > "$clipped_test_temp/package.log" 2>&1
assert_no_staging
unzip -tq "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip"
expected_hash=$("$CLIPPED_PATH_TEST_SHASUM" -a 256 "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip")
grep -Fx "SHA256: ${expected_hash%% *}" "$clipped_test_temp/package.log"
mv "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip" "$clipped_test_temp/final.zip"
mkdir "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip"
printf 'preserve directory\n' > "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip/sentinel"
: > "$CLIPPED_PATH_TEST_TOOLS"
if make -s -C "$clipped_test_project" package > "$clipped_test_temp/failure.log" 2>&1; then
    echo 'Packaging accepted a directory as the ZIP path.' >&2
    exit 1
fi
test "$(cat "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip/sentinel")" = 'preserve directory'
test ! -e "$CLIPPED_PATH_TEST_OUTPUT/Clipped.zip/Clipped.zip"
test ! -s "$CLIPPED_PATH_TEST_TOOLS"
assert_no_staging
echo 'Passed 25 build-path and packaging scenarios; no real builds, signing, or app launch ran.'
