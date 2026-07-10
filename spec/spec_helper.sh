#!/bin/sh

# Git exports repository-local environment variables to hooks. They can make
# nested test repositories operate on the outer repository instead.
if command -v git >/dev/null 2>&1; then
	unset $(git rev-parse --local-env-vars 2>/dev/null || :)
fi
