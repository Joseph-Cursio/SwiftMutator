prefix ?= /usr/local
bindir = $(prefix)/bin
libdir = $(prefix)/lib

repodir = $(shell pwd)
builddir = $(repodir)/.build

build:
	@swift package clean
	@swift build -c debug $(flags)

build-release: 
	@swift build -c release --product swift-mutator --disable-sandbox

project:
	@xed .

release: 
	@./Scripts/shipIt.sh $(version)

install: build-release
	@install -d "$(bindir)" "$(libdir)"
	@install "$(builddir)/release/swift-mutator" "$(bindir)"

uninstall:
	@rm -rf "$(bindir)/swift-mutator"

clean:
	@rm -rf .build

run: build
	@$(builddir)/debug/swift-mutator

test:
	@swift test --filter 'muterTests'
	
acceptance-test: build
	@./AcceptanceTests/runAcceptanceTests.sh

regression-test: build
	@./RegressionTests/runRegressionTests.sh

# Whole runs on a pinned SwiftProjectLint, checked mutant by mutant: about 3.5 hours (AcceptanceTests/slow/README.md).
slow-acceptance-test:
	@./AcceptanceTests/slow/slow-acceptance.sh

slow-acceptance-reference:
	@./AcceptanceTests/slow/slow-acceptance.sh --reference $(or $(RUNS),5)

slow-acceptance-selftest:
	@python3 -I AcceptanceTests/slow/test_verdicts.py

mutation-test: clean
	swift-mutator

.PHONY: build clean test run install uninstall release slow-acceptance-test slow-acceptance-reference slow-acceptance-selftest
