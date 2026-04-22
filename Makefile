.PHONY: build release test web dmg clean fmt fmt-check help

XCSTRINGS := macos/ccterm/Localizable.xcstrings
FMT_XCSTRINGS := python3 macos/scripts/fmt-xcstrings.py

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

build: ## Build ccterm (Debug)
	./macos/scripts/build.sh

release: ## Build ccterm (Release)
	./macos/scripts/build.sh release

test: ## Run unit tests (all). Pass TEST=<target> to scope, e.g. `make test TEST=cctermTests/TranscriptDiffTests`
	./macos/scripts/run-tests.sh $(TEST)

web: ## Build web frontend only
	cd web && bun install && bun run build

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

fmt: ## Format localization strings
	$(FMT_XCSTRINGS) $(XCSTRINGS)

fmt-check: ## Check formatting (CI)
	$(FMT_XCSTRINGS) --check $(XCSTRINGS)
	@if grep -nE '^\s*DEVELOPMENT_TEAM\s*=' macos/ccterm.xcodeproj/project.pbxproj; then \
		echo "error: DEVELOPMENT_TEAM must live in macos/Local.xcconfig, not project.pbxproj"; \
		exit 1; \
	fi

clean: ## Remove all build artifacts
	rm -rf ~/Library/Developer/Xcode/DerivedData/ccterm-*
	rm -rf web/node_modules web/dist
	rm -f macos/ccterm/Resources/*.js macos/ccterm/Resources/*.css macos/ccterm/Resources/*-react.html
