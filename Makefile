# Thin wrapper around xcodebuild(1), mirroring Hermes's Makefile.

XCB           = xcodebuild
CONFIGURATION = Debug
SCHEME        = Lyra
BUILD_DIR     = ./build
APP           = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/Lyra.app
COMMON_OPTS   = -project Lyra.xcodeproj -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR)

all: lyra

lyra:
	$(XCB) $(COMMON_OPTS) -configuration $(CONFIGURATION) build

run: lyra
	$(APP)/Contents/MacOS/Lyra

test:
	$(XCB) $(COMMON_OPTS) -only-testing:LyraKitTests test

# Release builds must be universal (arm64 + x86_64) so no Mac needs Rosetta.
verify-arch: CONFIGURATION = Release
verify-arch: lyra
	@for bin in $(APP)/Contents/MacOS/Lyra $(APP)/Contents/Frameworks/LyraKit.framework/LyraKit; do \
		archs=$$(lipo -archs $$bin); echo "$$bin: $$archs"; \
		case "$$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal"; exit 1;; esac; \
	done

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all lyra run test verify-arch clean
