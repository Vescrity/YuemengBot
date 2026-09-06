PREFIX      ?= /usr/local
VERSION     ?= 0.1.0
LUA_VERSION ?= 5.5
INSTALL     ?= install

SRC_DIR  := $(CURDIR)/src
LIB_DIR  := $(CURDIR)/lib

SHARE_DIR := $(PREFIX)/share/yuemeng
CLIB_DIR  := $(PREFIX)/lib/yuemeng/lua/$(LUA_VERSION)
BIN_DIR   := $(PREFIX)/bin

LUA_FILES := $(shell find $(SRC_DIR) -name '*.lua' | sort)
LIB_LUA   := $(shell find $(LIB_DIR) -name '*.lua' -not -path '*/test/*' | sort)
SO_FILES  := $(shell find $(LIB_DIR) -name '*.so')

install:
	@mkdir -p $(DESTDIR)$(SHARE_DIR)
	@for f in $(LUA_FILES); do \
		rel=$${f#$(SRC_DIR)/}; \
		$(INSTALL) -D -m 644 "$$f" "$(DESTDIR)$(SHARE_DIR)/$$rel"; \
	done
	@mkdir -p $(DESTDIR)$(SHARE_DIR)/promise $(DESTDIR)$(SHARE_DIR)/http
	@for f in $(LIB_LUA); do \
		rel=$${f#$(LIB_DIR)/}; \
		$(INSTALL) -m 644 "$$f" "$(DESTDIR)$(SHARE_DIR)/$$rel"; \
	done
	@mkdir -p $(DESTDIR)$(CLIB_DIR)
	@for f in $(SO_FILES); do \
		$(INSTALL) -m 644 "$$f" "$(DESTDIR)$(CLIB_DIR)/"; \
	done
	@mkdir -p $(DESTDIR)$(BIN_DIR)
	@sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@VERSION@|$(VERSION)|g' \
		bin/yuemeng.in > "$(DESTDIR)$(BIN_DIR)/yuemeng"
	@chmod +x "$(DESTDIR)$(BIN_DIR)/yuemeng"
	@$(INSTALL) -m 755 tools/yuedbg "$(DESTDIR)$(BIN_DIR)/yuedbg"

run:
	LUA_PATH="src/?.lua;src/?/init.lua;lib/promise/?.lua;lib/http/?.lua;;" \
	LUA_CPATH="lib/http/?.so;;" \
	lua src/main.lua $(ARGS)

.PHONY: install run
