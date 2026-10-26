APP           := tattle
BROKER        := tattle-capture-broker
APP_ID        := io.github.eladefrati.tattle
DEV_ID        := $(APP_ID).dev
CONFIG        ?= release
BUILD         := build
BIN           := .build/$(CONFIG)/$(APP)
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

.PHONY: build test app dev-app install run stop log clean

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BIN) $(APPDIR)/Contents/MacOS/$(APP)
	cp .build/$(CONFIG)/$(BROKER) $(APPDIR)/Contents/MacOS/$(BROKER)
	cp Resources/Info.plist $(APPDIR)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" $(APPDIR)/Contents/Info.plist
	plutil -replace CFBundleName -string "$(BUNDLE_NAME)" $(APPDIR)/Contents/Info.plist
	cp -R Resources/knowledge $(APPDIR)/Contents/Resources/knowledge
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
	@for f in $(APPDIR)/Contents/MacOS/$(APP) $(APPDIR)/Contents/MacOS/$(BROKER); do \
	  codesign --display --verbose $$f 2>&1 | grep -q 'flags=.*runtime' \
	    || { echo "error: $$f is not signed with the hardened runtime" >&2; exit 1; }; \
	  ! codesign --display --entitlements - $$f 2>/dev/null | grep -q get-task-allow \
	    || { echo "error: $$f carries get-task-allow" >&2; exit 1; }; \
	  ! otool -L $$f | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/Library/)' \
	    || { echo "error: $$f links a library outside the system, which library validation refuses ad hoc" >&2; exit 1; }; \
	done
	@codesign -dv $(APPDIR) 2>&1 | grep -E '^(Authority|TeamIdentifier)' || true

dev-app:
	$(MAKE) app APPDIR=$(DEVDIR) BUNDLE_ID=$(DEV_ID) BUNDLE_NAME="Tattle Dev"

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
