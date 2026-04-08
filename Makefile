SCHEME = Clipped
PROJECT_DIR = Clipped
BUILD_DIR = $(shell xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

.PHONY: build run test clean generate

build:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Debug build

run: build
	open "$(BUILD_DIR)/Clipped.app"

test:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Debug test

release:
	xcodebuild -project $(PROJECT_DIR)/Clipped.xcodeproj -scheme $(SCHEME) -configuration Release CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build
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
