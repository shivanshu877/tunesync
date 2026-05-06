APP        = TuneSync.app
BIN        = .build/release/TuneSync
PLIST      = $(APP)/Contents/Info.plist
RES        = $(APP)/Contents/Resources

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(RES)
	cp $(BIN) $(APP)/Contents/MacOS/TuneSync
	cp -R .build/release/TuneSync_TuneSync.bundle $(RES)/ 2>/dev/null || true
	cp -R .build/release/TuneSync.bundle $(RES)/ 2>/dev/null || true
	@printf '%s\n' \
'<?xml version="1.0" encoding="UTF-8"?>' \
'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
'<plist version="1.0">' \
'<dict>' \
'<key>CFBundleName</key><string>TuneSync</string>' \
'<key>CFBundleDisplayName</key><string>TuneSync</string>' \
'<key>CFBundleIdentifier</key><string>com.tunesync.app</string>' \
'<key>CFBundleVersion</key><string>0.1.0</string>' \
'<key>CFBundleShortVersionString</key><string>0.1.0</string>' \
'<key>CFBundleExecutable</key><string>TuneSync</string>' \
'<key>CFBundlePackageType</key><string>APPL</string>' \
'<key>LSMinimumSystemVersion</key><string>14.0</string>' \
'<key>NSHighResolutionCapable</key><true/>' \
'<key>NSBonjourServices</key><array><string>_tunesync._tcp</string></array>' \
'<key>NSLocalNetworkUsageDescription</key><string>TuneSync uses your local network to discover other Macs running TuneSync.</string>' \
'</dict>' \
'</plist>' > $(PLIST)
	@echo "Built $(APP)"

run: bundle
	open $(APP)

clean:
	rm -rf $(APP) .build
