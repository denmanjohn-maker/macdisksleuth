.PHONY: build release test generate app clean

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

clean:
	rm -rf .build App/DiskSleuth.xcodeproj
