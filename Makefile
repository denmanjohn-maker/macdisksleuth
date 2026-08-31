.PHONY: build release test generate app xcode clean

# xcodebuild needs full Xcode. If xcode-select points at the Command Line
# Tools (the default on many Macs), fall back to /Applications/Xcode.app.
# Permanent fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
DEVELOPER_DIR ?= $(shell if xcodebuild -version >/dev/null 2>&1; then xcode-select -p; else echo /Applications/Xcode.app/Contents/Developer; fi)
export DEVELOPER_DIR

build:
	swift build

release:
	swift build -c release

test:
	swift test

# Generate App/DiskSleuth.xcodeproj from App/project.yml (requires: brew install xcodegen)
generate:
	xcodegen generate --spec App/project.yml --project App

app: generate
	xcodebuild -project App/DiskSleuth.xcodeproj -scheme DiskSleuth -configuration Release build CODE_SIGN_IDENTITY=-

# Generate the project and open it in Xcode. Open THIS, not Package.swift —
# the Swift package only contains the CLI and library, not the app target.
xcode: generate
	open App/DiskSleuth.xcodeproj

clean:
	rm -rf .build App/DiskSleuth.xcodeproj
