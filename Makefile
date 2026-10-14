SCHEME = Clipped
PROJECT_DIR = Clipped

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

.PHONY: build run test test-build-paths release package clean generate format lint setup help

help:
	@echo "Available targets:"
	@echo "  build     - Debug build"
	@echo "  run       - Build and launch"
	@echo "  test      - Run unit tests"
	@echo "  test-build-paths - Check local build paths with stubbed Xcode and launch tools"
	@echo "  release   - Release build with local signing when available"
	@echo "  package   - Release build + zip for distribution"
	@echo "  clean     - Clean build artifacts"
	@echo "  generate  - Regenerate Xcode project from project.yml"
	@echo "  format    - Auto-format Swift code"
	@echo "  lint      - Check code style (swiftformat + swiftlint)"

build:
	xcodebuild -project "$(PROJECT_DIR)/Clipped.xcodeproj" -scheme "$(SCHEME)" -configuration Debug build $(SIGN_ARGS)

run: build
	@BUILT_DIR=$$(bash scripts/build-products-dir.sh "$(PROJECT_DIR)/Clipped.xcodeproj" "$(SCHEME)" Debug) || exit $$?; \
	open "$$BUILT_DIR/Clipped.app"

test:
	xcodebuild -project "$(PROJECT_DIR)/Clipped.xcodeproj" -scheme "$(SCHEME)" -configuration Debug test $(SIGN_ARGS)

test-build-paths:
	bash scripts/test-build-paths.sh

release:
	@echo "Note: For distributable builds, use the CI release workflow which handles Developer ID signing + notarization."
	xcodebuild -project "$(PROJECT_DIR)/Clipped.xcodeproj" -scheme "$(SCHEME)" -configuration Release build $(SIGN_ARGS)
	@BUILT_DIR=$$(bash scripts/build-products-dir.sh "$(PROJECT_DIR)/Clipped.xcodeproj" "$(SCHEME)" Release) || exit $$?; \
	echo "Built to: $$BUILT_DIR/Clipped.app"

package: release
	@BUILT_DIR=$$(bash scripts/build-products-dir.sh "$(PROJECT_DIR)/Clipped.xcodeproj" "$(SCHEME)" Release) || exit $$?; \
	cd "$$BUILT_DIR" && \
	ditto -c -k --keepParent Clipped.app Clipped.zip && \
	echo "Package ready: $$(pwd)/Clipped.zip" && \
	echo "SHA256: $$(shasum -a 256 Clipped.zip | awk '{print $$1}')"

clean:
	xcodebuild -project "$(PROJECT_DIR)/Clipped.xcodeproj" -scheme "$(SCHEME)" clean

generate:
	cd "$(PROJECT_DIR)" && xcodegen generate

format:
	swiftformat .

lint:
	swiftformat --lint .
	swiftlint lint --strict

setup:
	git config core.hooksPath .githooks
	@echo "Git hooks configured."
