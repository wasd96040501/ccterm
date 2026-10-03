.PHONY: build release install dmg clean fmt fmt-check test-unit test-kit test-sdk test-list bench-list record-list demo-kit demo-list logs icon sidebar-icons new-view-icons design-shots appkit-doc arch help

XCSTRINGS := macos/ccterm/Localizable.xcstrings
FMT_XCSTRINGS := python3 macos/scripts/fmt-xcstrings.py
SWIFT_FORMAT := swift-format
SWIFT_SRC := macos/ccterm macos/cctermTests macos/AgentSDK/Sources macos/AgentSDK/Tests macos/TranscriptKit/Sources macos/TranscriptKit/Tests macos/ExactList/Sources macos/ExactList/Tests macos/tools
PREFIX ?= /Applications

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

build: ## Build ccterm (Debug)
	./macos/scripts/build.sh

release: ## Build ccterm (Release)
	./macos/scripts/build.sh release

install: release ## Install Release build to $(PREFIX) (default: /Applications)
	./macos/scripts/install.sh "$(PREFIX)"

test-unit: ## Run unit tests (cctermTests) — fast, parallel-safe
	./macos/scripts/test-unit.sh "$(FILTER)"

# TranscriptKit is a standalone package, so its tests run under `swift test`
# rather than through the app's Xcode test target. Separate entry point on
# purpose: the package must stay testable without the app.
#
# `*SnapshotTests` are skipped unless named: they write window-server captures
# for someone to look at, and assert nothing a merge should wait on — the same
# split the app's `test-unit` makes.
test-kit: ## Run TranscriptKit's package tests (FILTER=SomeTests; snapshots only when named)
	@cd macos/TranscriptKit && \
		if [ -n "$(FILTER)" ]; then swift test --filter "$(FILTER)"; \
		else swift test --skip SnapshotTests; fi

# AgentSDK's own tests: protocol decoding, transcript reconstruction, and
# `Session` driven over stdio by a scripted fake CLI — no real `claude` needed.
test-sdk: ## Run AgentSDK's package tests (FILTER=SomeTests)
	@cd macos/AgentSDK && \
		if [ -n "$(FILTER)" ]; then swift test --filter "$(FILTER)"; \
		else swift test; fi

# ExactList is a standalone package: `swift test`, no Xcode project. The
# benchmarks are skipped here: they compare against NSTableView and mean
# something only under -O, which is `bench-list`.
test-list: ## Run ExactList's package tests (FILTER=SomeTests)
	@cd macos/ExactList && \
		if [ -n "$(FILTER)" ]; then swift test --filter "$(FILTER)"; \
		else swift test --skip ExactListBenchmarks; fi

bench-list: ## Run ExactList's benchmarks against NSTableView (-O)
	@cd macos/ExactList && swift test -c release --filter ExactListBenchmarks

# The demo's scenarios in a window off screen, captured frame by frame for eyes
# (SPEC §13). An executable, not a test: TCC attributes xctest to Xcode.app, so
# this runs as the terminal and uses its Screen Recording grant. FILTER is part
# of a recording's name. The -isysroot is demo-list's.
record-list: ## Record ExactList's demo scenarios to PNGs, a sheet and a movie (FILTER=stream)
	@cd macos/ExactList && swift run \
		-Xswiftc -Xclang-linker -Xswiftc -isysroot \
		-Xswiftc -Xclang-linker -Xswiftc "$$(xcrun --sdk macosx --show-sdk-path)" \
		ExactListRecordings $(FILTER)
	@echo "Recordings: /tmp/exactlist-recordings"

# The package's demo app: the checklist in Sources/ExactListDemo/CLAUDE.md.
# The -isysroot is demo-kit's, for the same reason (see there).
demo-list: ## Run ExactList's demo app
	@cd macos/ExactList && swift run \
		-Xswiftc -Xclang-linker -Xswiftc -isysroot \
		-Xswiftc -Xclang-linker -Xswiftc "$$(xcrun --sdk macosx --show-sdk-path)" \
		ExactListDemo

# The package's demo app — a real window over real markdown documents. Rendering
# has no other check: a probe can assert a row's height, not whether the
# document in it looks like a document. Runs in the foreground; Ctrl-C or close
# the window to stop it.
#
# The `-isysroot` is what makes it look like a current Mac app. AppKit picks its
# appearance by the SDK a binary records having been linked against, and
# SwiftPM's link records the deployment target (12.0) there instead: it calls
# the toolchain's `swiftc` directly, with no `SDKROOT`, and hands clang the SDK
# as `--sysroot` — which clang does not read the SDK's version from. `-isysroot`
# it does. Measured with `vtool -show-build`: sdk 12.0 without, the installed SDK's version with.
demo-kit: ## Run TranscriptKit's demo app
	@cd macos/TranscriptKit && swift run \
		-Xswiftc -Xclang-linker -Xswiftc -isysroot \
		-Xswiftc -Xclang-linker -Xswiftc "$$(xcrun --sdk macosx --show-sdk-path)" \
		TranscriptKitDemo

logs: ## Stream unified logs for THIS worktree's build product only (CONFIG=debug|release CATEGORY=Foo LEVEL=info|debug)
	@CONFIG="$(CONFIG)" CATEGORY="$(CATEGORY)" LEVEL="$(LEVEL)" ./macos/scripts/logs.sh

# Look up an AppKit symbol from Apple's official docs. SYMBOL=NSStackView for a
# class overview + member list; SYMBOL=NSStackView.orientation for one member's
# full docs. Responses cache under /tmp; runs offline on a cache hit.
appkit-doc: ## Look up an AppKit symbol (SYMBOL=NSStackView or SYMBOL=NSStackView.orientation)
	@test -n "$(SYMBOL)" || (echo "Usage: make appkit-doc SYMBOL=NSStackView[.member]" && exit 1)
	@python3 macos/scripts/appkit-doc.py "$(SYMBOL)"

# The architecture map an /arch-review reads instead of the code: parses the
# Swift sources (no app build) and rewrites build/arch/ from scratch — index.md
# plus one file per source directory with each type's dependencies, data flow
# (@Published, AsyncStream, @Observable, callbacks, delegates) and which of its
# members other units use. SCOPE takes names or paths, comma-separated.
# DETAIL=members adds, per unit, how each type's members call one another and
# write its state — what a simplification pass reads.
arch: ## Map structure + data flow to build/arch/ (SCOPE=core|app|kit|sdk|<dir under macos/>, DETAIL=members)
	@swift run --package-path macos/tools/ArchMap --quiet ArchMap "$(CURDIR)/macos" "$(CURDIR)/build/arch" "$(SCOPE)" "$(DETAIL)"

dmg: ## Create DMG installer (usage: make dmg APP=/path/to/ccterm.app)
	@test -n "$(APP)" || (echo "Usage: make dmg APP=/path/to/ccterm.app" && exit 1)
	create-dmg \
		--volname "CCTerm" \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "$$(basename $(APP))" 150 190 \
		--app-drop-link 450 190 \
		ccterm.dmg \
		"$(APP)"

# App icon: design/icon/src/design.ts is the source of truth. This regenerates
# macos/ccterm/AppIcon.icon (Icon Composer document, SVG layers) from it and,
# with Xcode 26+, renders every system appearance to design/icon/out/review.png
# and the in-app icon (Assets.xcassets/AppIconArt, Any + Dark) the New tab shows.
icon: ## Regenerate AppIcon.icon and the AppIconArt image set from design/icon (+ review renders in design/icon/out)
	cd design/icon && bun install --frozen-lockfile && bun run build

sidebar-icons: ## Regenerate the sidebar glyph assets (Assets.xcassets/Sidebar) from design/sidebar-icons
	cd design/sidebar-icons && bun run build

new-view-icons: ## Regenerate the New view's glyph assets (Assets.xcassets/NewView) from design/new-view-icons
	cd design/new-view-icons && bun run build

design-shots: ## Render the transcript design sheet's live parts to /tmp/design-shots (headless Chrome), for DesignParity
	node design/transcript/shots/capture.mjs

fmt: ## Format Swift sources and localization strings
	$(SWIFT_FORMAT) format --parallel --in-place --recursive $(SWIFT_SRC)
	$(FMT_XCSTRINGS) $(XCSTRINGS)

fmt-check: ## Check formatting (CI)
	$(SWIFT_FORMAT) lint --parallel --strict --recursive $(SWIFT_SRC)
	$(FMT_XCSTRINGS) --check $(XCSTRINGS)
	@if grep -nE '^\s*DEVELOPMENT_TEAM\s*=' macos/ccterm.xcodeproj/project.pbxproj; then \
		echo "error: DEVELOPMENT_TEAM must live in macos/Local.xcconfig, not project.pbxproj"; \
		exit 1; \
	fi

clean: ## Remove all build artifacts
	rm -rf ~/Library/Developer/Xcode/DerivedData/ccterm-*
