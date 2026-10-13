# Flight Simulator II for macOS.
#
#   make app        release build without the dev-only lab, assembled into build/FS2.app (ad-hoc signed)
#   make check-app  check the built bundle without launching it: Packaging/check-app.sh and no lab code
#   make test       unit and differential tests (the differential ones need the .d64)
#   make audit      the byte and modified-copy audits on the repository and the built app (needs the .d64)
#   make lab        the dev-only lab CLI: .build/release/fs2lab
#   make clean      remove build/ and SwiftPM's build products
#   make web-core   build the core modules for WebAssembly (the portability guard)
#   make web        the web build, assembled into build/web (with the deploy disk when there is one)
#   make web-serve  serve build/web on http://localhost:8064 with the isolation headers
#   make web-disk   the deploy disk (fs2disk): build/web-disk/FlightSimulatorII.d64, from $FS2_D64 or
#                   the app's imported copy (only the port's blocks, the crack's text blanked)
#   make web-audit  the audits on fs2.wasm and the deploy disk, and no .d64 tracked by git
#   make web-check  the port native and as wasm (under Node's V8) print the same digests; 30 nested
#                   restarts as wasm (the stack)
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

# The WebAssembly build uses swift.org's toolchain through swiftly (Xcode's cannot use the wasm
# Swift SDK), pinned with the SDK in web/toolchain.env. It has its own build directory.
include web/toolchain.env
# Where `swift` is that toolchain already (a CI container), `make WASM_SWIFT=swift`.
SWIFTLY  ?= $(shell command -v swiftly 2>/dev/null || echo $(HOME)/.swiftly/bin/swiftly)
WASM_SWIFT ?= $(SWIFTLY) run +$(WASM_SWIFT_VERSION) swift
WASM_FLAGS := --swift-sdk $(WASM_SDK) -c release --disable-default-traits --scratch-path .build-web
WASM_BUILD := $(CAPPED) $(BUILD_TIMEOUT) $(WASM_SWIFT) build $(WASM_FLAGS)

WEB      := build/web
WEB_DISK := build/web-disk/FlightSimulatorII.d64
WASM_OPT ?= $(shell command -v wasm-opt 2>/dev/null)

# The user's disk: $FS2_D64, else the copy the Mac app imported.
SOURCE_D64 ?= $(or $(FS2_D64),$(HOME)/Library/Application Support/FS2/FlightSimulatorII.d64)

WEB_CHECK := build/web-check

.PHONY: all app check-app test audit lab clean icon web-core web web-serve web-disk web-audit web-check

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

# The three core modules compile for wasm32-wasip1 (no Apple-only API, no threads in shipping
# paths). Cheap enough to run after any change to C64Kit, FS2Data or FS2Core.
web-core:
	$(WASM_BUILD) --target FS2Core

# The page (web/), fs2.wasm (optimized by Binaryen's wasm-opt when it is installed) and, when
# `make web-disk` made one, the scrubbed deploy disk. build/ is ignored: nothing here is committed.
web:
	$(WASM_BUILD) --product FS2Web
	rm -rf "$(WEB)"
	mkdir -p "$(WEB)"
	cp web/*.html web/*.css web/*.js "$(WEB)/"
	@wasm="$$($(WASM_SWIFT) build $(WASM_FLAGS) --show-bin-path)/FS2Web.wasm"; \
	if [ -n "$(WASM_OPT)" ]; then \
		echo "wasm-opt -Oz $$wasm"; "$(WASM_OPT)" -Oz --strip-debug --strip-producers "$$wasm" -o "$(WEB)/fs2.wasm"; \
	else \
		echo "note: wasm-opt (Binaryen) is not installed; fs2.wasm is not optimized"; cp "$$wasm" "$(WEB)/fs2.wasm"; \
	fi
	@if [ -f "$(WEB_DISK)" ]; then cp "$(WEB_DISK)" "$(WEB)/"; \
	else echo "note: no deploy disk (make web-disk); the page will ask for one"; fi
	@ls -l "$(WEB)"

web-serve:
	Scripts/serve-web.py "$(WEB)" 8064

web-disk:
	@test -f "$(SOURCE_D64)" || { echo "error: no disk image at $(SOURCE_D64) (set FS2_D64)"; exit 1; }
	mkdir -p "$(dir $(WEB_DISK))"
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) run -c release fs2disk "$(SOURCE_D64)" "$(WEB_DISK)"
	@shasum -a 256 "$(WEB_DISK)"

# The audits of `make audit` on the web build: fs2.wasm holds no SubLogic bytes and names nothing
# of the crack; the deploy disk is fs2disk's image of the user's disk; git tracks no disk image.
# (The page's own files are tracked, so the repository audit covers them.)
web-audit: web
	@if git ls-files | grep -i -E '\.(d64|d71|d81|g64|prg|rom)$$'; then \
		echo "error: git tracks a disk or ROM image"; exit 1; fi
	$(CAPPED) $(BUILD_TIMEOUT) $(WASM_SWIFT) build --swift-sdk $(WASM_SDK) -c release \
		--package-path Scripts/wasm-baseline --scratch-path .build-web-baseline
	mkdir -p build/web-audit
	@baseline="$$($(WASM_SWIFT) build --swift-sdk $(WASM_SDK) -c release \
		--package-path Scripts/wasm-baseline --scratch-path .build-web-baseline --show-bin-path)/WasmBaseline.wasm"; \
	if [ -n "$(WASM_OPT)" ]; then "$(WASM_OPT)" -Oz --strip-debug --strip-producers "$$baseline" -o build/web-audit/baseline.wasm; \
	else cp "$$baseline" build/web-audit/baseline.wasm; fi
	FS2_AUDIT_BINARY="$(CURDIR)/$(WEB)/fs2.wasm" FS2_AUDIT_BASELINE="$(CURDIR)/build/web-audit/baseline.wasm" \
	FS2_AUDIT_DISK="$(if $(wildcard $(WEB)/FlightSimulatorII.d64),$(CURDIR)/$(WEB)/FlightSimulatorII.d64,)" \
		$(CAPPED) $(AUDIT_TIMEOUT) $(SWIFT) test --filter '$(AUDIT_SUITES)|DeployDiskTests'

# fs2check drives the port inline with a fake clock and a scripted player and prints digests of
# the frames, the sound and memory: natively and as wasm they must be identical. Needs Node.
web-check:
	@test -f "$(SOURCE_D64)" || { echo "error: no disk image at $(SOURCE_D64) (set FS2_D64)"; exit 1; }
	@command -v node >/dev/null || { echo "error: web-check runs the wasm under Node (not found)"; exit 1; }
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) build -c release --product fs2check
	$(WASM_BUILD) --product fs2check
	mkdir -p "$(WEB_CHECK)"
	"$$($(SWIFT) build -c release --show-bin-path)/fs2check" session < "$(SOURCE_D64)" \
		| grep -v '^stack' > "$(WEB_CHECK)/native.txt"
	@wasm="$$($(WASM_SWIFT) build $(WASM_FLAGS) --show-bin-path)/fs2check.wasm"; \
	node --no-warnings Scripts/run-wasi.mjs "$$wasm" session < "$(SOURCE_D64)" | grep -v '^stack' > "$(WEB_CHECK)/wasm.txt" && \
	diff "$(WEB_CHECK)/native.txt" "$(WEB_CHECK)/wasm.txt" && \
	echo "web-check: native and wasm identical ($$(wc -l < "$(WEB_CHECK)/native.txt" | tr -d ' ') digests)" && \
	node --no-warnings Scripts/run-wasi.mjs "$$wasm" restarts 30 < "$(SOURCE_D64)" | tail -2

clean:
	rm -rf build .build-app .build-web .build-web-baseline
	$(CAPPED) $(BUILD_TIMEOUT) $(SWIFT) package clean
