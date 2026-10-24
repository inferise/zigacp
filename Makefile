###############################################
#
# Makefile — zigacp
#
# `make validate` is the pre-commit gate; `make build` is the entry point.
#
###############################################

# Optional include to extend the makefile targets
-include ../styleguide/Makefile.in

# The Zig sources, tools/ included.
ZIG_DIRS := src tools

.DEFAULT_GOAL := all

.PHONY: build dist run

# ---------------------------------------------
# Configuration
# ---------------------------------------------

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# ---------------------------------------------
# Primary workflows
# ---------------------------------------------

# Build, format, and test.
all: build format test
	@echo "done"

# Extend the canonical pre-commit gate with the Windows build.
validate: windows

# ---------------------------------------------
# Build
# ---------------------------------------------

# Build the library and CLI.
build:
	zig build

# Build optimized for release.
dist:
	zig build --release=fast

# Build and run the reference agent (yopo). Pass arguments with `make run ARGS="..."`.
run:
	zig build run -- $(ARGS)

# Run the cookbook client and agent examples.
demo:
	zig build demo

# ---------------------------------------------
# Cross-compilation
# ---------------------------------------------

# Compile for Linux.
linux:
	zig build -Dtarget=x86_64-linux

# Compile for Windows.
windows:
	zig build -Dtarget=x86_64-windows

# List every target Zig can build for.
targets:
	zig targets

# ---------------------------------------------
# Test
# ---------------------------------------------

# Run the unit test suite.
test:
	zig build test --summary all

# ---------------------------------------------
# Documentation
# ---------------------------------------------

# Build the API docs and serve them locally.
docs:
	zig build docs
	open "http://127.0.0.1:8080" &
	python3 -m http.server -b 127.0.0.1 8080 -d zig-out/docs

# ---------------------------------------------
# Release
# ---------------------------------------------

# Tag the build.zig.zon version (e.g. 1.0.0) and push it.
tag:
	@test -n "$(VERSION)" || { echo "❌ could not read .version from build.zig.zon"; exit 1; }
	git tag -a "$(VERSION)" -m "$(VERSION)"
	git push
	git push --tags

# ---------------------------------------------
# Environment
# ---------------------------------------------

# Open the working copy in SourceTree.
st:
	open -a SourceTree .

# Open the project in the editor.
open:
	code .

# Open the repository on GitHub.
github:
	open "https://github.com/inferise/zigacp"

# Clone a fresh working copy.
clone:
	git clone git@github.com:inferise/zigacp.git

# Start Claude Code here.
claude:
	claude

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

# Remove every build artifact.
clean:
	rm -rf .zig-cache
	rm -rf zig-out
