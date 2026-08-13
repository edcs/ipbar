APP_NAME  := IPBar
BUNDLE    := $(APP_NAME).app
VERSION   ?= 0.1.0
DIST      := dist
ARM_BIN   := .build/arm64-apple-macosx/release/$(APP_NAME)
X86_BIN   := .build/x86_64-apple-macosx/release/$(APP_NAME)

# Set these to sign/notarize. SIGN_ID is a "Developer ID Application: ..." identity
# from `security find-identity -v -p codesigning`; NOTARY_PROFILE is a keychain
# profile created with `xcrun notarytool store-credentials`.
SIGN_ID        ?=
NOTARY_PROFILE ?= ipbar-notary

.PHONY: all app debug run clean sign notarize release icon hooks screenshots

all: app

## Enable the versioned git hooks (Conventional Commits). Run once per clone —
## git does not share hook config across clones.
hooks:
	git config core.hooksPath .githooks
	@echo "commit-msg hook enabled"

debug:
	swift build

## Redraw the icon from Tools/GenerateIcon.swift and compile it to .icns
icon:
	swift Tools/GenerateIcon.swift
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Redraw the README screenshots, in both appearances
screenshots: app
	@mkdir -p Screenshots
	@for scheme in light dark; do \
		IPBAR_PROBE=panel IPBAR_PANEL_SAMPLE=1 IPBAR_PANEL_SCHEME=$$scheme \
		IPBAR_PANEL_OUT=Screenshots/panel-$$scheme.png IPBAR_STRIP_OUT=Screenshots/menubar-$$scheme.png \
		$(DIST)/$(BUNDLE)/Contents/MacOS/$(APP_NAME); \
	done

## Universal (arm64 + x86_64) .app bundle in dist/
##
## Each slice is built on its own and merged with lipo. The one-shot form,
## `swift build --arch arm64 --arch x86_64`, routes through xcbuild and fails
## on GitHub's macos-15 runner; per-triple builds use the ordinary SwiftPM
## build system and work everywhere.
app: Resources/AppIcon.icns
	swift build -c release --triple arm64-apple-macosx
	swift build -c release --triple x86_64-apple-macosx
	rm -rf $(DIST)/$(BUNDLE)
	mkdir -p $(DIST)/$(BUNDLE)/Contents/MacOS $(DIST)/$(BUNDLE)/Contents/Resources
	lipo -create -output $(DIST)/$(BUNDLE)/Contents/MacOS/$(APP_NAME) $(ARM_BIN) $(X86_BIN)
	cp Resources/AppIcon.icns $(DIST)/$(BUNDLE)/Contents/Resources/AppIcon.icns
	cp -R Resources/Flags $(DIST)/$(BUNDLE)/Contents/Resources/Flags
	sed 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > $(DIST)/$(BUNDLE)/Contents/Info.plist
	@echo "built $(DIST)/$(BUNDLE) ($(VERSION))"

Resources/AppIcon.icns:
	$(MAKE) icon

run: app
	@pkill -x $(APP_NAME) || true
	open $(DIST)/$(BUNDLE)

sign: app
	@test -n "$(SIGN_ID)" || (echo "SIGN_ID is required, e.g. make sign SIGN_ID='Developer ID Application: You (TEAMID)'"; exit 1)
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(DIST)/$(BUNDLE)
	codesign --verify --strict --verbose=2 $(DIST)/$(BUNDLE)

notarize: sign
	ditto -c -k --keepParent $(DIST)/$(BUNDLE) $(DIST)/$(APP_NAME)-notarize.zip
	xcrun notarytool submit $(DIST)/$(APP_NAME)-notarize.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DIST)/$(BUNDLE)
	rm -f $(DIST)/$(APP_NAME)-notarize.zip

## Notarized, stapled zip ready to attach to a GitHub release
release: notarize
	ditto -c -k --keepParent $(DIST)/$(BUNDLE) $(DIST)/$(APP_NAME)-$(VERSION).zip
	shasum -a 256 $(DIST)/$(APP_NAME)-$(VERSION).zip

clean:
	rm -rf .build $(DIST)
