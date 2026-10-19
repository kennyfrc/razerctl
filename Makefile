PREFIX ?= $(HOME)/.local/bin

build:
	swift build -c release

install: build
	install -d "$(PREFIX)"
	install .build/release/razerctl "$(PREFIX)/razerctl"

clean:
	rm -rf .build
