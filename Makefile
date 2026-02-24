APP_NAME    = ClaudeBattery
BUNDLE      = $(APP_NAME).app
BINARY      = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
SOURCES     = $(wildcard Sources/*.swift)
SDK         = $(shell xcrun --show-sdk-path --sdk macosx)
SWIFT       = $(shell xcrun -f swiftc)
# Build for the host architecture (arm64 on Apple Silicon, x86_64 on Intel)
ARCH        = $(shell uname -m)
TARGET      = $(ARCH)-apple-macos13.0

.PHONY: all build install clean run

all: build

## Compile sources and assemble the .app bundle
build: $(SOURCES) Info.plist
	@echo "▶  Compiling $(APP_NAME)..."
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	$(SWIFT) \
		-target $(TARGET) \
		-sdk $(SDK) \
		-framework SwiftUI \
		-framework AppKit \
		-framework Foundation \
		-framework ServiceManagement \
		-framework Security \
		$(SOURCES) \
		-o $(BINARY)
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	@echo "✓  Built $(BUNDLE)"

## Launch directly (useful for testing; Ctrl-C to stop)
run: build
	@echo "▶  Launching $(BUNDLE)..."
	@open $(BUNDLE)

## Copy to /Applications
install: build
	@echo "▶  Installing to /Applications..."
	@cp -R $(BUNDLE) /Applications/$(BUNDLE)
	@echo "✓  Installed — you can now open it from /Applications or Spotlight"

## Remove build artefacts
clean:
	@rm -rf $(BUNDLE)
	@echo "✓  Cleaned"
