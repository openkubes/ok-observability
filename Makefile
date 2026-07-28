# ok-observability — deterministic verification entry points (OK-100 pilot)
#
# Stable commands for humans and AI agents. All targets are deterministic
# and independent of any LLM. See AGENTS.md for the workflow.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help deps verify verify-structure verify-links verify-secrets verify-charts verify-vso-template conformance evidence

# The profile is a TWO-level umbrella: profiles/ok-observability-standard depends
# on the three implementations/* wrapper charts, and each of those depends on an
# upstream chart. `helm dependency build` only resolves ONE level, and packaging a
# wrapper whose own charts/ is empty yields a .tgz with no upstream inside — so
# building only the profile renders EMPTY and would install a release containing
# nothing. Nested charts/ and Chart.lock are git-ignored, so a fresh clone always
# starts in that state. Build the inner level first, then the profile.
IMPLEMENTATIONS := implementations/prometheus implementations/grafana implementations/opensearch
PROFILE         := profiles/ok-observability-standard

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

deps: ## Build chart dependencies at BOTH umbrella levels (required before helm template/install)
	@set -euo pipefail; \
	for impl in $(IMPLEMENTATIONS); do \
		echo "DEPS: $$impl"; \
		helm dependency build "$$impl" >/dev/null || helm dependency update --skip-refresh "$$impl" >/dev/null; \
	done; \
	echo "DEPS: $(PROFILE)"; \
	helm dependency build $(PROFILE) >/dev/null || helm dependency update --skip-refresh $(PROFILE) >/dev/null; \
	echo "DEPS: all levels built."

verify: verify-structure verify-links verify-secrets verify-charts verify-vso-template ## Run all fast deterministic repository checks
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

verify-vso-template: ## VSO template must stay equivalent to the proven ok-robotics example
	@python3 scripts/check_vso_template.py

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
