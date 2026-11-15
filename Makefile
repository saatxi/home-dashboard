# Tasques de desenvolupament. Cap objectiu toca el dispositiu.
SHELL := /bin/bash
SH_FILES := $(wildcard scripts/*.sh scripts/tests/*.sh)

.DEFAULT_GOAL := help
.PHONY: help lint test kiosk check

help: ## Mostra aquesta llista d'objectius
	@echo "Objectius disponibles:"
	@awk -F'[:#]+ *' '/^[a-z-]+:.*## /{printf "  %-14s%s\n", $$1, $$NF}' $(MAKEFILE_LIST)

lint: ## shellcheck i bash -n de tots els scripts
	shellcheck -x -P scripts $(SH_FILES)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@echo "lint: correcte"

test: ## Tests dels scripts amb un adb fals (no toca cap dispositiu)
	scripts/tests/run-tests.sh

kiosk: ## Compila l'APK del kiosk (scripts/build-kiosk.sh)
	scripts/build-kiosk.sh

check: lint test ## lint + test
