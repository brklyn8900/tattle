APP           := tattle
BROKER        := tattle-capture-broker
BUNDLE_ID     := io.github.eladefrati.tattle
CONFIG        ?= release
BUILD         := build
BIN           := .build/$(CONFIG)/$(APP)
APPDIR        := $(BUILD)/Tattle.app
# First Apple Development identity in the keychain; override with SIGN_IDENTITY=... if needed.
# A stable identity keeps TCC grants across rebuilds; ad-hoc signing resets them every time.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $$2; exit}')

.PHONY: build test app install run stop log clean

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
	cp -R Resources/knowledge $(APPDIR)/Contents/Resources/knowledge
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
	  codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APPDIR)/Contents/MacOS/$(BROKER); \
	  codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APPDIR); \
	else \
	  echo "warning: no Apple Development identity found; signing ad hoc, permission grants will reset on every rebuild" >&2; \
	  codesign --force --sign - $(APPDIR)/Contents/MacOS/$(BROKER); \
	  codesign --force --sign - $(APPDIR); \
	fi
	@codesign -dv $(APPDIR) 2>&1 | grep -E '^(Authority|TeamIdentifier)' || true

install: app
	rm -rf /Applications/Tattle.app
	cp -R $(APPDIR) /Applications/

run: app stop
	open $(APPDIR)

stop:
	-pkill -x $(APP)

log:
	/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf $(BUILD) .build
