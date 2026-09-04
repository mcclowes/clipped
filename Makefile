SCHEME = Clipped
PROJECT_DIR = Clipped
BUILD_DIR = $(shell xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

# Sign local builds with the Developer ID when the certificate is on this machine.
#
# An ad-hoc signature pins the designated requirement to the binary's cdhash, so every
# rebuild looks like a brand-new app: the login Keychain re-prompts for the password on
# each build ("Always Allow" whitelists a cdhash that no longer exists), and TCC grants
# reset the same way. Signing with the same identity the shipped app uses makes the
# requirement identity-based and therefore stable across rebuilds.
#
# CI has no certificate, so this expands to nothing there and Xcode falls back to ad-hoc.
DEVELOPER_ID_TEAM := $(shell security find-identity -v -p codesigning 2>/dev/null | \
	sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]*\))".*/\1/p' | head -1)
SIGN_ARGS := $(if $(DEVELOPER_ID_TEAM),CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
	DEVELOPMENT_TEAM=$(DEVELOPER_ID_TEAM) PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGNING_ALLOWED=YES,)

.PHONY: build run test release package clean generate format lint setup help

help:
	@echo "Available targets:"
	@echo "  build     - Debug build"
	@echo "  run       - Build and launch"
	@echo "  test      - Run unit tests"
	@echo "  release   - Release build (unsigned)"
	@echo "  package   - Release build + zip for distribution"
	@echo "  clean     - Clean build artifacts"
	@echo "  generate  - Regenerate Xcode project from project.yml"
	@echo "  format    - Auto-format Swift code"
	@echo "  lint      - Check code style (swiftformat + swiftlint)"

build:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Debug build $(SIGN_ARGS)

run: build
	open "$(BUILD_DIR)/Clipped.app"

test:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Debug test

release:
	@echo "Note: For distributable builds, use the CI release workflow which handles Developer ID signing + notarization."
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Release build
	@echo "Built to: $(BUILD_DIR)/../Release/Clipped.app"

package: release
	cd "$$(xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')" && \
	ditto -c -k --keepParent Clipped.app Clipped.zip && \
	echo "Package ready: $$(pwd)/Clipped.zip" && \
	echo "SHA256: $$(shasum -a 256 Clipped.zip | awk '{print $$1}')"

clean:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) clean

generate:
	cd $(PROJECT_DIR) && xcodegen generate

format:
	swiftformat .

lint:
	swiftformat --lint .
	swiftlint lint --strict

setup:
	git config core.hooksPath .githooks
	@echo "Git hooks configured."
