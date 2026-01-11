# Makefile for kernel-auto-bisect tool (Modular Framework)

# Installation directories
PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin/kernel-auto-bisect
HANDLER_DIR_TARGET := $(BIN_DIR)/handlers
CONFIG_FILE_TARGET := $(BIN_DIR)/bisect.conf

# Source files and directories
SCRIPT_SRC := kab.sh
LIB_SRC := lib.sh
CRIU_DAEMON_SRC := criu-daemon.sh
CONFIG_SRC := bisect.conf
HANDLER_SRC_DIR := handlers
HANDLER_SRCS := $(wildcard $(HANDLER_SRC_DIR)/*.sh)

.PHONY: all install uninstall clean help

all: help

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install      Install the bisection scripts, CRIU daemon and handlers."
	@echo "  uninstall    Remove all installed files."
	@echo "  help         Show this help message."

format-check:
	@command -v shfmt >/dev/null 2>&1 || { echo "Error: shfmt not found. Please install it."; exit 1; }
	shfmt -d kab.sh lib.sh handlers/*.sh
	shfmt -d tests/*/*.sh

static-analysis:
	@command -v shellcheck >/dev/null 2>&1 || { echo "Error: shellcheck not found. Please install it."; exit 1; }
	shellcheck -x kab.sh lib.sh handlers/*.sh

TMT_CONTEXT_ARG := $(shell test -f KAB_TMT_CONTEXT && echo "-c @KAB_TMT_CONTEXT")

integration-tests:
	tmt $(TMT_CONTEXT_ARG) run -a

tests: format-check static-analysis integration-tests

install:
	@if [ "$(EUID)" -ne 0 ]; then \
		echo "Please run as root or with sudo."; \
		exit 1; \
	fi
	@echo "Installing kernel-auto-bisect tool (modular)..."
	@echo "Creating directories: $(BIN_DIR) and $(HANDLER_DIR_TARGET)"
	@mkdir -p $(HANDLER_DIR_TARGET)

	@echo "Copying orchestrator script to $(BIN_DIR)/$(SCRIPT_SRC)"
	@cp $(SCRIPT_SRC) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/$(SCRIPT_SRC)
	@cp $(LIB_SRC) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/$(LIB_SRC)

	@echo "Copying CRIU daemon to $(BIN_DIR)/$(CRIU_DAEMON_SRC)"
	@cp $(CRIU_DAEMON_SRC) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/$(CRIU_DAEMON_SRC)

	@echo "Copying handler scripts to $(HANDLER_DIR_TARGET)/"
	@cp $(HANDLER_SRCS) $(HANDLER_DIR_TARGET)/
	@chmod +x $(HANDLER_DIR_TARGET)/*.sh

	@if [ ! -f "$(CONFIG_FILE_TARGET)" ]; then \
		echo "Copying default configuration to $(CONFIG_FILE_TARGET)"; \
		cp $(CONFIG_SRC) $(CONFIG_FILE_TARGET); \
	fi
	@echo ""
	@echo "Installation complete."
	@echo "IMPORTANT: Please edit the configuration file at $(CONFIG_FILE_TARGET) before starting the bisection."

uninstall:
	@if [ "$(EUID)" -ne 0 ]; then \
		echo "Please run as root or with sudo."; \
		exit 1; \
	fi
	@echo "Uninstalling kernel-auto-bisect tool..."

	@echo "Removing script directory: $(BIN_DIR)"
	@rm -rf $(BIN_DIR)
	@echo ""
	@echo "Uninstallation complete."
	@echo "Note: work directory /var/local/kernel-auto-bisect and fake RPM repo are not removed."

clean:
	@echo "Nothing to clean."
