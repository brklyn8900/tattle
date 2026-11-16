APP           := tattle
BROKER        := tattle-capture-broker
APP_ID        := io.github.eladefrati.tattle
DEV_ID        := $(APP_ID).dev
CONFIG        ?= release
BUILD         := build
# The architectures make app builds, joined into one universal binary (empty builds this Mac's
# own only, as a plain swift build does), and the version it stamps into the app. Both are
# taken from the command line only, as make release passes them: make reads every
# environment variable as a variable, and one exported under either name must not change
# what make app or make run builds.
ifneq ($(origin ARCHS),command line)
override ARCHS :=
endif
ifneq ($(origin VERSION),command line)
override VERSION :=
endif
BINDIR       := $(if $(ARCHS),.build/universal/$(CONFIG),.build/$(CONFIG))
BIN           := $(BINDIR)/$(APP)
# What make app bundles: the release app unless dev-app overrides all three.
APPDIR        := $(BUILD)/Tattle.app
BUNDLE_ID     := $(APP_ID)
BUNDLE_NAME   := Tattle
# make run builds and stops only this copy, with its own bundle id and data folder, so it
# never replaces or kills a release build that is running from build/Tattle.app.
DEVDIR        := $(BUILD)/TattleDev.app
# First Apple Development identity in the keychain; override with SIGN_IDENTITY=... if needed.
# A stable identity keeps TCC grants across rebuilds; ad-hoc signing resets them every time.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $$2; exit}')
# The main thread's stack size, fixed in the app's binary so that a stack limit Tattle inherits
# cannot make its startup overflow before it drops its exception ports (ADR-0003). Only the
# app's own link carries it: ld refuses it for the test bundle, which links the app's code too,
# and a plain swift build links the app again without it.
APP_STACK     := 0x800000
# make release builds here, so it never replaces a release build running from build/Tattle.app.
DISTDIR       := $(BUILD)/dist

.PHONY: build test app dev-app release icon install run stop log clean

build:
	swift build -c $(CONFIG)

test:
	swift test

# Each product on its own: `build` would link the app without its stack size first.
app:
ifeq ($(ARCHS),)
	swift build -c $(CONFIG) --product $(BROKER)
	swift build -c $(CONFIG) --product $(APP) -Xlinker -stack_size -Xlinker $(APP_STACK)
else
	@set -e; for a in $(ARCHS); do \
	  swift build -c $(CONFIG) --arch $$a --product $(BROKER); \
	  swift build -c $(CONFIG) --arch $$a --product $(APP) -Xlinker -stack_size -Xlinker $(APP_STACK); \
	done; \
	mkdir -p "$(BINDIR)"; \
	for p in $(BROKER) $(APP); do \
	  set --; \
	  for a in $(ARCHS); do set -- "$$@" "$$(swift build -c $(CONFIG) --arch $$a --show-bin-path)/$$p"; done; \
	  lipo -create -output "$(BINDIR)/$$p" "$$@"; \
	done
endif
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/$(APP)
	cp $(BINDIR)/$(BROKER) $(APPDIR)/Contents/MacOS/$(BROKER)
	cp Resources/Info.plist $(APPDIR)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" $(APPDIR)/Contents/Info.plist
	plutil -replace CFBundleName -string "$(BUNDLE_NAME)" $(APPDIR)/Contents/Info.plist
	$(if $(VERSION),plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APPDIR)/Contents/Info.plist)
	$(if $(VERSION),plutil -replace CFBundleVersion -string "$(VERSION)" $(APPDIR)/Contents/Info.plist)
	cp -R Resources/knowledge $(APPDIR)/Contents/Resources/knowledge
	cp Resources/AppIcon.icns $(APPDIR)/Contents/Resources/AppIcon.icns
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
	  codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APPDIR)/Contents/MacOS/$(BROKER); \
	  codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APPDIR); \
	else \
	  echo "warning: no Apple Development identity found; signing ad hoc, permission grants will reset on every rebuild" >&2; \
	  codesign --force --options runtime --sign - $(APPDIR)/Contents/MacOS/$(BROKER); \
	  codesign --force --options runtime --sign - $(APPDIR); \
	fi
	@# The broker refuses a caller another process could steer (ADR-0003); fail here instead.
	@# The runtime brings library validation, which ad hoc admits only system libraries.
	@# Each check runs on every architecture in the binary: each slice is signed on its own. A
	@# binary whose architectures cannot be read fails, or the checks would run on none.
	@for f in $(APPDIR)/Contents/MacOS/$(APP) $(APPDIR)/Contents/MacOS/$(BROKER); do \
	  archs=$$(lipo -archs $$f) && [ -n "$$archs" ] \
	    || { echo "error: cannot read the architectures of $$f" >&2; exit 1; }; \
	  for a in $$archs; do \
	    codesign --display --verbose --arch $$a $$f 2>&1 | grep -q 'flags=.*runtime' \
	      || { echo "error: $$f ($$a) is not signed with the hardened runtime" >&2; exit 1; }; \
	    ! codesign --display --entitlements - --arch $$a $$f 2>/dev/null | grep -q get-task-allow \
	      || { echo "error: $$f ($$a) carries get-task-allow" >&2; exit 1; }; \
	    ! otool -arch $$a -L $$f | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/Library/)' \
	      || { echo "error: $$f ($$a) links a library outside the system, which library validation refuses ad hoc" >&2; exit 1; }; \
	  done; \
	done
	@archs=$$(lipo -archs $(APPDIR)/Contents/MacOS/$(APP)) && [ -n "$$archs" ] \
	  || { echo "error: cannot read the architectures of $(APPDIR)/Contents/MacOS/$(APP)" >&2; exit 1; }; \
	for a in $$archs; do \
	  otool -arch $$a -l $(APPDIR)/Contents/MacOS/$(APP) | grep -A4 LC_MAIN | grep -q "stacksize $$(printf %d $(APP_STACK))" \
	    || { echo "error: $(APPDIR)/Contents/MacOS/$(APP) ($$a) does not fix its main thread's stack size" >&2; exit 1; }; \
	done
	@codesign -dv $(APPDIR) 2>&1 | grep -E '^(Authority|TeamIdentifier)' || true

dev-app:
	$(MAKE) app APPDIR=$(DEVDIR) BUNDLE_ID=$(DEV_ID) BUNDLE_NAME="Tattle Dev"

# What a release ships: the app for Apple silicon and Intel, signed ad hoc and stamped with
# VERSION (YYYY.MM.DD.N), zipped with ditto so the bundle and its signature survive, and the
# zip's SHA-256 checksum.
release:
	@echo "$(VERSION)" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*$$' \
	  || { echo "error: give the version as VERSION=YYYY.MM.DD.N" >&2; exit 1; }
	rm -rf $(DISTDIR)
	$(MAKE) app APPDIR=$(DISTDIR)/Tattle.app ARCHS="arm64 x86_64" SIGN_IDENTITY=- VERSION=$(VERSION)
	cd $(DISTDIR) && ditto -c -k --sequesterRsrc --keepParent Tattle.app Tattle-$(VERSION).zip
	@# The zip must give back an app whose signature still holds.
	mkdir $(DISTDIR)/unzipped
	ditto -x -k $(DISTDIR)/Tattle-$(VERSION).zip $(DISTDIR)/unzipped
	codesign --verify --strict --deep $(DISTDIR)/unzipped/Tattle.app
	rm -rf $(DISTDIR)/unzipped
	cd $(DISTDIR) && shasum -a 256 Tattle-$(VERSION).zip > Tattle-$(VERSION).zip.sha256

# Redraws Resources/AppIcon.icns from Resources/AppIcon.svg; run it after the drawing changes.
icon:
	rm -rf $(BUILD)/AppIcon.iconset
	mkdir -p $(BUILD)/AppIcon.iconset
	@for s in 16 32 128 256 512; do \
	  sips -s format png -z $$s $$s Resources/AppIcon.svg --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s * 2)); \
	  sips -s format png -z $$d $$d Resources/AppIcon.svg --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns -o Resources/AppIcon.icns $(BUILD)/AppIcon.iconset

install: app
	rm -rf /Applications/Tattle.app
	cp -R $(APPDIR) /Applications/

run: dev-app stop
	open $(DEVDIR)

# By executable path, anchored so it matches neither the release app nor a shell whose
# command line merely contains the path.
stop:
	-pkill -f '^$(abspath $(DEVDIR))/Contents/MacOS/$(APP)$$'

log:
	/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "$(APP_ID)" OR subsystem == "$(DEV_ID)"'

clean:
	rm -rf $(BUILD) .build
