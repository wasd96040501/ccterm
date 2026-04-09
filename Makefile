.PHONY: build release test web dmg clean fmt fmt-check

XCSTRINGS := macos/ccterm/Localizable.xcstrings
FMT_XCSTRINGS := python3 macos/scripts/fmt-xcstrings.py

build:
	./macos/scripts/build.sh

release:
	./macos/scripts/build.sh release

test:
	./macos/scripts/run-tests.sh

web:
	cd web && bun install && bun run build

dmg:
	@test -n "$(APP)" || (echo "Usage: make dmg APP=/path/to/ccterm.app" && exit 1)
	create-dmg \
		--volname "CCTerm" \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "$$(basename $(APP))" 150 190 \
		--app-drop-link 450 190 \
		ccterm.dmg \
		"$(APP)"

fmt:
	$(FMT_XCSTRINGS) $(XCSTRINGS)

fmt-check:
	$(FMT_XCSTRINGS) --check $(XCSTRINGS)
	@if grep -nE '^\s*DEVELOPMENT_TEAM\s*=' macos/ccterm.xcodeproj/project.pbxproj; then \
		echo "error: DEVELOPMENT_TEAM must live in macos/Local.xcconfig, not project.pbxproj"; \
		exit 1; \
	fi

clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/ccterm-*
	rm -rf web/node_modules web/dist
	rm -f macos/ccterm/Resources/*.js macos/ccterm/Resources/*.css macos/ccterm/Resources/*-react.html
