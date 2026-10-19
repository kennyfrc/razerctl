PREFIX ?= $(HOME)/.local

build:
	swift build -c release

# Ad-hoc signing with a fixed identifier and designated requirement, so the Input
# Monitoring grant sticks to "razerctl" and survives rebuilds.
install: build
	install -d "$(PREFIX)/bin"
	install -m 755 .build/release/razerctl "$(PREFIX)/bin/razerctl"
	codesign --force --sign - --identifier local.razerctl \
		--requirements='=designated => identifier "local.razerctl"' "$(PREFIX)/bin/razerctl"
	-launchctl kickstart -k gui/$$(id -u)/local.razerctl

clean:
	rm -rf .build

.PHONY: build install clean
