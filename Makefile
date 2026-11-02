LUAJIT ?= luajit
LUA_PATH_VALUE := ./lua/?.lua;./lua/?/init.lua;./tests/?.lua;;
PREFIX ?= /usr/local
LUA_VERSION ?= 5.1
LUA_SHAREDIR ?= $(PREFIX)/share/lua/$(LUA_VERSION)
LUA_MODULE_DIR ?= $(LUA_SHAREDIR)/questdb
DESTDIR ?=
INSTALL ?= install

LUA_MODULES := $(wildcard lua/questdb/*.lua)

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)

ifeq ($(UNAME_S),Darwin)
  PLATFORM     := macos
  LIB_FILENAME := libquestdb_client.dylib
else ifeq ($(UNAME_S),Linux)
  PLATFORM     := linux
  LIB_FILENAME := libquestdb_client.so
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  PLATFORM     := windows
  LIB_FILENAME := questdb_client.dll
else
  PLATFORM     := $(shell echo $(UNAME_S) | tr '[:upper:]' '[:lower:]')
  LIB_FILENAME := libquestdb_client.so
endif

# ---------------------------------------------------------------------------
# Upstream c-questdb-client
# ---------------------------------------------------------------------------
UPSTREAM_REPO   ?= https://github.com/questdb/c-questdb-client
# Pinned to the commit the FFI declarations are checked against (7.0.0+2).
UPSTREAM_COMMIT ?= 8ef0219fbcec6f88ceb12e2f3a346ca6e3a8c91c

BUILD_DIR       := build
UPSTREAM_DIR    := $(BUILD_DIR)/c-questdb-client
UPSTREAM_BUILD  := $(UPSTREAM_DIR)/build-$(PLATFORM)
UPSTREAM_PIN    := $(BUILD_DIR)/upstream-commit
LIB_OUT_DIR     := $(BUILD_DIR)/lib
LIB_OUT         := $(LIB_OUT_DIR)/$(LIB_FILENAME)

# The pinned upstream crates declare `rust-version = "1.91.1"` (edition 2024).
RUST_MIN_VERSION ?= 1.91.1

CC    ?= cc
CMAKE ?= cmake
JOBS  ?= $(shell (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4))

# rustup's default location is often missing from non-login shells. Exported
# here rather than in a recipe so that the toolchain check and the CMake build
# see the same Rust.
ifeq (,$(shell command -v cargo 2>/dev/null))
  ifneq (,$(wildcard $(HOME)/.cargo/bin/cargo))
    export PATH := $(HOME)/.cargo/bin:$(PATH)
  endif
endif

.PHONY: all deps deps-check upstream-src abi-check test ffi-smoke integration check install clean clean-deps print-config check-rust

all: deps

## check-rust: fail early with an actionable message on an old toolchain.
check-rust:
	@for tool in cargo rustc; do \
	  if ! command -v $$tool >/dev/null 2>&1; then \
	    echo "error: $$tool not found. Install Rust $(RUST_MIN_VERSION)+ from https://rustup.rs" >&2; \
	    exit 1; \
	  fi; \
	  have=$$($$tool --version | sed -E "s/^[a-z]+ ([0-9]+\.[0-9]+\.[0-9]+).*/\1/"); \
	  if [ "$$(printf "%s\n%s\n" "$(RUST_MIN_VERSION)" "$$have" | sort -V | head -1)" != "$(RUST_MIN_VERSION)" ]; then \
	    echo "error: $$tool $$have is too old; the pinned upstream needs $(RUST_MIN_VERSION)+" >&2; \
	    echo "       run: rustup update stable" >&2; \
	    exit 1; \
	  fi; \
	  echo ">> $$tool $$have OK"; \
	done

## upstream-src: put the upstream source tree at the pinned commit.
upstream-src:
	@mkdir -p $(BUILD_DIR)
	@if [ ! -d "$(UPSTREAM_DIR)/.git" ]; then \
	  echo ">> cloning $(UPSTREAM_REPO)"; \
	  git clone --quiet "$(UPSTREAM_REPO)" "$(UPSTREAM_DIR)"; \
	fi
	@if [ "$$(git -C "$(UPSTREAM_DIR)" rev-parse HEAD)" != "$$(git -C "$(UPSTREAM_DIR)" rev-parse --verify --quiet '$(UPSTREAM_COMMIT)^{commit}')" ]; then \
	  if ! git -C "$(UPSTREAM_DIR)" cat-file -e '$(UPSTREAM_COMMIT)^{commit}' 2>/dev/null; then \
	    echo ">> fetching $(UPSTREAM_REPO)"; \
	    git -C "$(UPSTREAM_DIR)" fetch --quiet origin; \
	  fi; \
	  echo ">> checking out $(UPSTREAM_COMMIT)"; \
	  git -C "$(UPSTREAM_DIR)" checkout --quiet '$(UPSTREAM_COMMIT)'; \
	  git -C "$(UPSTREAM_DIR)" submodule update --init --recursive --quiet; \
	fi

## deps: clone (if needed) and build the upstream C client as a shared library.
deps: $(LIB_OUT)

# $(UPSTREAM_PIN) records the commit the library was built from, written only
# after a successful build. Compared here rather than through file timestamps,
# which cannot be trusted to order a pin change against the library: any mismatch
# rebuilds, including moving back to an earlier commit.
ifneq ($(UPSTREAM_COMMIT),$(shell cat "$(UPSTREAM_PIN)" 2>/dev/null))
.PHONY: $(LIB_OUT)
endif

# The toolchain and source steps run inside the recipe: as prerequisites they
# would be phony, and would demand cargo even with an up-to-date library.
$(LIB_OUT):
	@$(MAKE) --no-print-directory check-rust upstream-src
	@echo ">> configuring c-questdb-client for $(PLATFORM)"
	@$(CMAKE) -S "$(UPSTREAM_DIR)" -B "$(UPSTREAM_BUILD)" \
	  -DBUILD_SHARED_LIBS=ON \
	  -DCMAKE_BUILD_TYPE=Release \
	  -DQUESTDB_TESTS_AND_EXAMPLES=OFF
	@echo ">> building c-questdb-client ($(JOBS) jobs)"
	@MAKEFLAGS= $(CMAKE) --build "$(UPSTREAM_BUILD)" --config Release -j $(JOBS)
	@mkdir -p $(LIB_OUT_DIR)
	@found=$$(find "$(UPSTREAM_BUILD)" -name '$(LIB_FILENAME)' -type f -print -quit); \
	  if [ -z "$$found" ]; then \
	    echo "error: $(LIB_FILENAME) was not produced by the build" >&2; exit 1; \
	  fi; \
	  cp "$$found" "$@.tmp" && mv -f "$@.tmp" "$@" && echo ">> installed $$found -> $@"
	@printf '%s\n' "$(UPSTREAM_COMMIT)" > "$(UPSTREAM_PIN)"

## deps-check: report which shared library the module would load.
deps-check:
	@LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tools/check.lua

## abi-check: compile the Lua view of the ABI against the pinned upstream header.
abi-check: upstream-src
	@LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tools/abi_check.lua > $(BUILD_DIR)/abi_check.c
	@$(CC) -std=c11 -fsyntax-only -I"$(UPSTREAM_DIR)/include" $(BUILD_DIR)/abi_check.c
	@rm -f $(BUILD_DIR)/abi_check.c
	@echo ">> ABI declarations match $(UPSTREAM_COMMIT)"

## test: everything that runs without a QuestDB server.
test:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/run.lua

ffi-smoke:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/test_ffi.lua

## integration: live write/read test; fails if the server cannot be reached.
##   make integration QUESTDB_TEST_HTTP=localhost:9000
integration: deps
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/test_integration.lua

## check: build the dependency if needed, then run every offline check.
check: deps abi-check
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/run.lua
	@LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tools/check.lua

install: $(LUA_MODULES)
	$(INSTALL) -d "$(DESTDIR)$(LUA_MODULE_DIR)"
	$(INSTALL) -m 0644 $(LUA_MODULES) "$(DESTDIR)$(LUA_MODULE_DIR)/"

print-config:
	@echo "platform:  $(PLATFORM)"
	@echo "library:   $(LIB_FILENAME)"
	@echo "luajit:    $(LUAJIT)"
	@echo "cmake:     $(CMAKE)"
	@echo "jobs:      $(JOBS)"
	@echo "lib out:   $(LIB_OUT)"

clean:
	rm -rf $(UPSTREAM_BUILD) $(LIB_OUT_DIR) $(UPSTREAM_PIN)

clean-deps:
	rm -rf $(UPSTREAM_DIR) $(LIB_OUT_DIR) $(UPSTREAM_PIN)
