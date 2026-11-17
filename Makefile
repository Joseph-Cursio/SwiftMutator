prefix ?= /usr/local
bindir = $(prefix)/bin
libdir = $(prefix)/lib

repodir = $(shell pwd)
builddir = $(repodir)/.build

# An incremental build: `make clean` removes .build when a clean one is needed.
build:
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

# Whole runs on a pinned project, checked mutant by mutant (AcceptanceTests/slow/README.md). SLOW_TARGET picks the
# project, from AcceptanceTests/slow/targets: SwiftProjectLint by default, about 12 hours.
SLOW_TARGET ?= swiftprojectlint

slow-acceptance-test:
	@./AcceptanceTests/slow/slow-acceptance.sh --target $(SLOW_TARGET)

# Every target in turn; fails if any does.
slow-acceptance-test-all:
	@status=0; for target in $$(./AcceptanceTests/slow/slow-acceptance.sh --targets); do \
	  ./AcceptanceTests/slow/slow-acceptance.sh --target $$target || status=1; done; exit $$status

slow-acceptance-reference:
	@./AcceptanceTests/slow/slow-acceptance.sh --target $(SLOW_TARGET) --reference $(or $(RUNS),5)

slow-acceptance-selftest:
	@python3 -I AcceptanceTests/slow/test_verdicts.py

# No clean first: the copied build files aren't reused in the run's copy, so removing .build saved no time.
mutation-test:
	swift-mutator

.PHONY: build clean test run install uninstall release slow-acceptance-test slow-acceptance-test-all slow-acceptance-reference slow-acceptance-selftest
