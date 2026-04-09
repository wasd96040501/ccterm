.PHONY: build release test web dmg clean

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

clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/ccterm-*
	rm -rf web/node_modules web/dist
	rm -f macos/ccterm/Resources/*.js macos/ccterm/Resources/*.css macos/ccterm/Resources/*-react.html
