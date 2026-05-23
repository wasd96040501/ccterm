.PHONY: build release install dmg clean fmt fmt-check test-unit js-bundles help

XCSTRINGS := macos/ccterm/Localizable.xcstrings
FMT_XCSTRINGS := python3 macos/scripts/fmt-xcstrings.py
SWIFT_FORMAT := swift-format
SWIFT_SRC := macos/ccterm macos/cctermTests macos/AgentSDK/Sources
PREFIX ?= /Applications

# JSCore bundles — compiled from js/ on demand. Outputs are gitignored; the
# `js-bundles` target rebuilds them when sources / lockfile change, so
# `make build` is self-sufficient on a clean clone.
JS_BUNDLE_OUTPUTS := macos/ccterm/Resources/hljs-jscore.js
JS_BUNDLE_SOURCES := $(shell find js/bundles js/scripts -type f 2>/dev/null) \
                     js/package.json js/bun.lock

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

$(JS_BUNDLE_OUTPUTS): $(JS_BUNDLE_SOURCES)
	cd js && bun install --frozen-lockfile && bun run scripts/build.ts

js-bundles: $(JS_BUNDLE_OUTPUTS) ## Rebuild JSCore bundles (hljs-jscore.js)

build: js-bundles ## Build ccterm (Debug)
	./macos/scripts/build.sh

release: js-bundles ## Build ccterm (Release)
	./macos/scripts/build.sh release

install: release ## Install Release build to $(PREFIX) (default: /Applications)
	./macos/scripts/install.sh "$(PREFIX)"

test-unit: js-bundles ## Run unit tests (cctermTests) — fast, parallel-safe
	./macos/scripts/test-unit.sh "$(FILTER)"

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
