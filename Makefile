.PHONY: build release dmg clean fmt fmt-check test test-all help

XCSTRINGS := macos/ccterm/Localizable.xcstrings
FMT_XCSTRINGS := python3 macos/scripts/fmt-xcstrings.py
SWIFT_FORMAT := swift-format
SWIFT_SRC := macos/ccterm macos/cctermUITests macos/AgentSDK/Sources

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

build: ## Build ccterm (Debug)
	./macos/scripts/build.sh

release: ## Build ccterm (Release)
	./macos/scripts/build.sh release

test: ## Run UI test — REQUIRES FILTER=ClassName or ClassName/method (see CLAUDE.md)
	@test -n "$(FILTER)" || (echo "error: FILTER is required. Examples:"; \
		echo "  make test FILTER=InputBar2StopButtonUITests"; \
		echo "  make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState"; \
		echo "  make test-all   # 全量跑(慢,慎用)"; \
		exit 1)
	./macos/scripts/test.sh "$(FILTER)"

test-all: ## Run all UI tests (slow; only when full coverage explicitly needed)
	ALLOW_FULL_RUN=1 ./macos/scripts/test.sh ""

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
