LUAJIT ?= luajit
LUA_PATH_VALUE := ./lua/?.lua;./lua/?/init.lua;./tests/?.lua;;

.PHONY: test ffi-smoke

test:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/run.lua

ffi-smoke:
	LUA_PATH='$(LUA_PATH_VALUE)' $(LUAJIT) tests/test_ffi.lua
