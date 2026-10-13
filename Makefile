# Flight Simulator II for macOS.
#
#   make app        release build without the dev-only lab, assembled into build/FS2.app (ad-hoc signed)
#   make check-app  check the built bundle without launching it: Packaging/check-app.sh and no lab code
#   make test       unit and differential tests (the differential ones need the .d64)
#   make audit      the byte and modified-copy audits on the repository and the built app (needs the .d64)
#   make lab        the dev-only lab CLI: .build/release/fs2lab
#   make clean      remove build/ and SwiftPM's build products
#
# In sandboxed shells, SwiftPM has to run outside the sandbox.
#
# Every swift invocation runs under Scripts/capped, a hard wall-clock cap that kills the whole
# process group on timeout (exit status 142), so a hung build, test or helper such as
# swiftpm-testing-helper fails loudly instead of waiting forever. The caps are in seconds.

SWIFT    ?= swift
CAPPED   := Scripts/capped
APP      := build/FS2.app
CONTENTS := $(APP)/Contents
ICONSET  := build/FS2.iconset

# A build (the app, the lab, the icon script, a clean).
BUILD_TIMEOUT ?= 900
# The whole test suite: about 20 minutes in a debug build (the differential suites dominate).
TEST_TIMEOUT ?= 2400
# The audit suites (a filtered test run, with the test build it may need first).
AUDIT_TIMEOUT ?= 900

# The shipped app is built without the package trait `Lab` (see Package.swift), so it links neither
# the lab (FS2LabKit) nor its 6502 core (M6502). It has its own build directory, so it never
# replaces the development build in .build (whose FS2 keeps `--engine lab`).
APP_BUILD := $(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) build -c release --product FS2 --disable-default-traits \
	--scratch-path .build-app

.PHONY: all app check-app test audit lab clean icon

all: app

app:
	$(APP_BUILD)
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$$($(APP_BUILD) --show-bin-path)/FS2" "$(CONTENTS)/MacOS/FS2"
	cp Packaging/Info.plist "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if $(MAKE) --no-print-directory icon; then \
		cp build/FS2.icns "$(CONTENTS)/Resources/FS2.icns"; \
	else \
		echo "note: icon generation failed; the app uses the generic icon (check-app reports it)"; \
	fi
	codesign --force --sign - --timestamp=none "$(APP)"
	@$(MAKE) --no-print-directory check-app
	@echo "Built $(APP)"

# The bundle (Packaging/check-app.sh: Info.plist, executable, icon, PkgInfo, ad-hoc signature), and
# the shipped binary must not contain the lab: no symbol or metadata string of the FS2LabKit or
# M6502 modules, and no dynamic library of theirs.
check-app:
	@test -x "$(CONTENTS)/MacOS/FS2" || { echo "error: $(APP) is not built (make app)"; exit 1; }
	Packaging/check-app.sh "$(APP)"
	@if nm -a "$(CONTENTS)/MacOS/FS2" | grep -E -q 'FS2LabKit|M6502'; then \
		echo "error: the lab (FS2LabKit/M6502) is linked into $(APP)"; exit 1; fi
	@if strings -a "$(CONTENTS)/MacOS/FS2" | grep -E -q 'FS2LabKit|M6502'; then \
		echo "error: $(APP) contains lab (FS2LabKit/M6502) metadata"; exit 1; fi
	@if otool -L "$(CONTENTS)/MacOS/FS2" | grep -E -q 'FS2LabKit|M6502'; then \
		echo "error: $(APP) loads a lab library"; exit 1; fi
	@echo "$(APP): no lab code (FS2LabKit/M6502)"

# A simple generated icon (optional).
icon: build/FS2.icns

build/FS2.icns: Packaging/make-icon.swift
	rm -rf "$(ICONSET)"
	mkdir -p build
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) Packaging/make-icon.swift "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o build/FS2.icns

test:
	$(CAPPED) $(TEST_TIMEOUT) $(SWIFT) test

# The modified-copy and SubLogic-bytes audits (re/docs/excluded.md), over the repository and the
# shipped binary: the compiler can lay a port's constants out as a table the sources never spell
# as one. The suites read the disk at run time and are skipped without it.
AUDIT_SUITES := CrackExclusionTests|SubLogicBytesAuditTests

audit: app
	FS2_AUDIT_BINARY="$(CURDIR)/$(CONTENTS)/MacOS/FS2" \
		$(CAPPED) $(AUDIT_TIMEOUT) $(SWIFT) test --filter '$(AUDIT_SUITES)'

lab:
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) build -c release --product fs2lab

clean:
	rm -rf build .build-app
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) package clean
