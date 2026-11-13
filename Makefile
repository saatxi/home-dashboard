# Tasques de desenvolupament. Cap objectiu toca el dispositiu.
SHELL := /bin/bash
VENV := server/.venv
PYTHON := $(VENV)/bin/python
SH_FILES := $(wildcard scripts/*.sh scripts/tests/*.sh)
PY_FILES := $(wildcard server/*.py scripts/*.py) scripts/tests/bin/adb

.DEFAULT_GOAL := help
.PHONY: help lint venv test test-server test-scripts serve kiosk check

help: ## Mostra aquesta llista d'objectius
	@echo "Objectius disponibles:"
	@awk -F'[:#]+ *' '/^[a-z-]+:.*## /{printf "  %-14s%s\n", $$1, $$NF}' $(MAKEFILE_LIST)

# py_compile deixa __pycache__/ (ignorat per .gitignore)
lint: ## shellcheck, bash -n i py_compile de tots els scripts
	shellcheck -x -P scripts $(SH_FILES)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	python3 -m py_compile $(PY_FILES)
	@echo "lint: correcte"

$(VENV)/.installed: server/requirements.txt server/requirements-dev.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -r server/requirements-dev.txt
	@touch $@

venv: $(VENV)/.installed ## Crea server/.venv i instal·la les dependències de desenvolupament

test: test-server test-scripts ## Executa tots els tests (servidor i scripts)

test-server: venv ## Tests Python del servidor (pytest)
	$(PYTHON) -m pytest server/tests

test-scripts: ## Tests dels scripts amb un adb fals (no toca cap dispositiu)
	scripts/tests/run-tests.sh

serve: ## Serveix el dashboard en local (scripts/serve-dashboard.sh)
	scripts/serve-dashboard.sh

kiosk: ## Compila l'APK del kiosk (scripts/build-kiosk.sh)
	scripts/build-kiosk.sh

check: lint test ## lint + test
