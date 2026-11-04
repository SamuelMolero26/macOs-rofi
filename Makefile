# Command Line Tools ships Swift Testing but leaves it off the default search
# path. With full Xcode selected, plain `swift test` works too.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS)

.PHONY: build lint test check

build:
	swift build

lint:
	swift format lint --configuration .swift-format --recursive --parallel --strict Package.swift Sources Tests

test:
	swift test $(TEST_FLAGS)

check:
	$(MAKE) lint
	$(MAKE) test
