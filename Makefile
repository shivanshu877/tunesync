APP        = TuneSync.app
BIN        = .build/release/TuneSync
PLIST      = $(APP)/Contents/Info.plist
RES        = $(APP)/Contents/Resources
DMG        = TuneSync-0.1.0.dmg
DMG_STAGE  = .dmg-stage

.PHONY: build bundle sign dmg run clean

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

sign: bundle
	codesign --force --deep --sign - $(APP)
	@echo "Ad-hoc signed (no developer ID — Gatekeeper will still warn on first open)"

dmg: sign
	rm -rf $(DMG_STAGE) $(DMG)
	mkdir -p $(DMG_STAGE)
	cp -R $(APP) $(DMG_STAGE)/
	ln -s /Applications $(DMG_STAGE)/Applications
	hdiutil create \
		-volname "TuneSync" \
		-srcfolder $(DMG_STAGE) \
		-ov \
		-format UDZO \
		$(DMG)
	rm -rf $(DMG_STAGE)
	@echo ""
	@echo "Built $(DMG) ($$(du -h $(DMG) | cut -f1))"
	@echo ""
	@echo "First-launch note: macOS will say 'cannot be opened because the developer"
	@echo "cannot be verified.' Right-click the app -> Open -> Open. Required only once."
	@echo "Or run:  xattr -dr com.apple.quarantine /Applications/TuneSync.app"

run: bundle
	open $(APP)

clean:
	rm -rf $(APP) .build $(DMG) $(DMG_STAGE)
