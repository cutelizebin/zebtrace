.PHONY: build run install icon test check package release-package clean

build:
	./scripts/build.sh

run:
	./scripts/run.sh

install:
	./scripts/install.sh

icon:
	./scripts/build-icon.sh

test:
	swift test

check:
	./scripts/check.sh

package:
	./scripts/package.sh --preview

release-package:
	./scripts/package.sh --release

clean:
	@if /usr/bin/pgrep -x 'ZebTrace|MyContext' >/dev/null 2>&1; then echo "Quit ZebTrace and any legacy MyContext instance before cleaning its app bundle." >&2; exit 1; fi
	swift package clean
	rm -rf dist/ZebTrace.app dist/ZebTrace-demo.zip
