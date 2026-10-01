SHELL := /bin/bash

FIXTURE ?= multi-project-running
NATIVE_FLOW_FIXTURE ?= empty-board
HARNESS := ./scripts/balagan-harness.sh

.PHONY: help build test ui-test ui-controls-smoke ui-flow-smoke ui-native-flow-smoke ui-daily-driver-smoke terminal-input-smoke terminal-manual-input-smoke terminal-visible-typing-smoke terminal-control-keys-smoke terminal-keyboard-shortcuts-smoke terminal-navigation-smoke terminal-state-smoke terminal-restart-resume-smoke agent-reopen-smoke hook-smoke hook-lifecycle-smoke agent-wrapper-smoke terminal-reload-prompt-smoke terminal-close-open-prompt-smoke terminal-ended-autoclose-smoke ui-debug normal-store-smoke first-run-smoke live-backend-smoke lint validate-fixtures

help:
	@printf '%s\n' "Balagan development commands"
	@printf '%s\n' "  make build"
	@printf '%s\n' "  make test"
	@printf '%s\n' "  make ui-test"
	@printf '%s\n' "  make ui-controls-smoke"
	@printf '%s\n' "  make ui-flow-smoke"
	@printf '%s\n' "  make ui-native-flow-smoke"
	@printf '%s\n' "  make ui-daily-driver-smoke"
	@printf '%s\n' "  make terminal-input-smoke"
	@printf '%s\n' "  make terminal-manual-input-smoke"
	@printf '%s\n' "  make terminal-visible-typing-smoke"
	@printf '%s\n' "  make terminal-control-keys-smoke"
	@printf '%s\n' "  make terminal-keyboard-shortcuts-smoke"
	@printf '%s\n' "  make terminal-navigation-smoke"
	@printf '%s\n' "  make terminal-state-smoke"
	@printf '%s\n' "  make terminal-restart-resume-smoke"
	@printf '%s\n' "  make agent-reopen-smoke"
	@printf '%s\n' "  make hook-smoke"
	@printf '%s\n' "  make hook-lifecycle-smoke"
	@printf '%s\n' "  make agent-wrapper-smoke"
	@printf '%s\n' "  make terminal-reload-prompt-smoke"
	@printf '%s\n' "  make terminal-close-open-prompt-smoke"
	@printf '%s\n' "  make terminal-ended-autoclose-smoke"
	@printf '%s\n' "  make ui-debug FIXTURE=multi-project-running"
	@printf '%s\n' "  make normal-store-smoke"
	@printf '%s\n' "  make first-run-smoke"
	@printf '%s\n' "  make live-backend-smoke"
	@printf '%s\n' "  make lint"

build:
	$(HARNESS) build

test:
	$(HARNESS) test

ui-test:
	FIXTURE="$(FIXTURE)" $(HARNESS) ui-test

ui-controls-smoke:
	FIXTURE="$(FIXTURE)" $(HARNESS) ui-controls-smoke "$(FIXTURE)"

ui-flow-smoke:
	FIXTURE="$(FIXTURE)" $(HARNESS) ui-flow-smoke "$(FIXTURE)"

ui-native-flow-smoke:
	FIXTURE="$(NATIVE_FLOW_FIXTURE)" $(HARNESS) ui-native-flow-smoke "$(NATIVE_FLOW_FIXTURE)"

ui-daily-driver-smoke:
	FIXTURE="$(NATIVE_FLOW_FIXTURE)" $(HARNESS) ui-daily-driver-smoke "$(NATIVE_FLOW_FIXTURE)"

terminal-input-smoke:
	$(HARNESS) terminal-input-smoke

terminal-manual-input-smoke:
	$(HARNESS) terminal-manual-input-smoke

terminal-visible-typing-smoke:
	$(HARNESS) terminal-visible-typing-smoke

terminal-control-keys-smoke:
	$(HARNESS) terminal-control-keys-smoke

terminal-keyboard-shortcuts-smoke:
	$(HARNESS) terminal-keyboard-shortcuts-smoke

terminal-navigation-smoke:
	$(HARNESS) terminal-navigation-smoke

terminal-state-smoke:
	FIXTURE="$(FIXTURE)" $(HARNESS) terminal-state-smoke "$(FIXTURE)"

terminal-restart-resume-smoke:
	$(HARNESS) terminal-restart-resume-smoke

agent-reopen-smoke:
	$(HARNESS) agent-reopen-smoke

hook-smoke:
	$(HARNESS) hook-smoke

hook-lifecycle-smoke:
	$(HARNESS) hook-lifecycle-smoke

agent-wrapper-smoke:
	$(HARNESS) agent-wrapper-smoke

terminal-reload-prompt-smoke:
	$(HARNESS) terminal-reload-prompt-smoke

terminal-close-open-prompt-smoke:
	$(HARNESS) terminal-close-open-prompt-smoke

terminal-ended-autoclose-smoke:
	$(HARNESS) terminal-ended-autoclose-smoke

ui-debug:
	FIXTURE="$(FIXTURE)" $(HARNESS) ui-debug "$(FIXTURE)"

normal-store-smoke:
	FIXTURE="$(FIXTURE)" $(HARNESS) normal-store-smoke "$(FIXTURE)"

first-run-smoke:
	$(HARNESS) first-run-smoke

live-backend-smoke:
	$(HARNESS) live-backend-smoke

lint:
	$(HARNESS) lint

validate-fixtures:
	$(HARNESS) validate-fixtures

app:
	./scripts/build-app.sh
