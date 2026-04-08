SCHEME = Clippers
PROJECT_DIR = Clippers
BUILD_DIR = $(shell xcodebuild -project $(PROJECT_DIR)/Clippers.xcodeproj -scheme $(SCHEME) -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

.PHONY: build run test clean generate

build:
	xcodebuild -project $(PROJECT_DIR)/Clippers.xcodeproj -scheme $(SCHEME) -configuration Debug build

run: build
	open "$(BUILD_DIR)/Clippers.app"

test:
	xcodebuild -project $(PROJECT_DIR)/Clippers.xcodeproj -scheme $(SCHEME) -configuration Debug test

clean:
	xcodebuild -project $(PROJECT_DIR)/Clippers.xcodeproj -scheme $(SCHEME) clean

generate:
	cd $(PROJECT_DIR) && xcodegen generate
