LUAJIT ?= luajit
LUA_PATH_VALUE := ./lua/?.lua;./lua/?/init.lua;./tests/?.lua;;
PREFIX ?= /usr/local
LUA_VERSION ?= 5.1
LUA_SHAREDIR ?= $(PREFIX)/share/lua/$(LUA_VERSION)
LUA_MODULE_DIR ?= $(LUA_SHAREDIR)/questdb
DESTDIR ?=
INSTALL ?= install

LUA_MODULES := $(wildcard lua/questdb/*.lua)

.PHONY: test ffi-smoke install

test:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/run.lua

ffi-smoke:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/test_ffi.lua

install: $(LUA_MODULES)
	$(INSTALL) -d "$(DESTDIR)$(LUA_MODULE_DIR)"
	$(INSTALL) -m 0644 $(LUA_MODULES) "$(DESTDIR)$(LUA_MODULE_DIR)/"
