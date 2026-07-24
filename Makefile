# ok-observability — deterministic verification entry points (OK-100 pilot)
#
# Stable commands for humans and AI agents. All targets are deterministic
# and independent of any LLM. See AGENTS.md for the workflow.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help verify verify-structure verify-links verify-secrets verify-charts conformance evidence

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

verify: verify-structure verify-links verify-secrets verify-charts ## Run all fast deterministic repository checks
	@echo ""
	@echo "VERIFY: all checks passed."

verify-structure: ## Required files and directories exist
	@./scripts/verify-structure.sh

verify-links: ## Relative markdown links resolve
	@python3 scripts/check_links.py

verify-secrets: ## No obvious secrets/credentials committed
	@python3 scripts/check_secrets.py

verify-charts: ## Structural chart check (NOT a substitute for helm lint/template — see scripts/check_charts.py)
	@python3 scripts/check_charts.py

conformance: ## Execute the ADR-018 Contract Test Gate (readiness gate)
	@if [ -x tests/contract-test.sh ]; then \
		echo "CONFORMANCE: running Contract Test Gate (tests/contract-test.sh)"; \
		tests/contract-test.sh; \
	else \
		echo "CONFORMANCE: FAIL — Contract Test Gate not yet implemented." >&2; \
		echo "  The gate is specified in tests/README.md and is a deliverable of OK-79" >&2; \
		echo "  (ok-cluster integration). Expected entry point: tests/contract-test.sh" >&2; \
		echo "  Do NOT weaken this target to make it pass (see AGENTS.md)." >&2; \
		exit 1; \
	fi

evidence: ## Produce a Jira-comment-ready evidence block from verify + conformance results
	@./scripts/evidence.sh
