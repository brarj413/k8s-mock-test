SHELL := bash
SCRIPTS := $(shell git ls-files '*.sh')

.PHONY: help container-up container-test container-down examples check-examples lint

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

container-up: ## Install KWOK + fake-gpu-operator and create the fake GPU nodes
	./container/up.sh

container-test: ## Check the fake nodes and schedule GPU test pods on them
	./container/test.sh

container-down: ## Remove the fake nodes, fake-gpu-operator and KWOK
	./container/down.sh

examples: ## Re-render container/examples from gpus/*.env
	./hack/render-examples.sh

check-examples: examples ## Fail if container/examples is out of date
	git diff --exit-code -- container/examples

lint: ## bash -n and shellcheck every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	shellcheck -x $(SCRIPTS)
