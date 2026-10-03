TF_DIRS := bootstrap modules/vpc modules/app-stack $(wildcard projects/*)
TF_TEST_DIRS := $(sort $(patsubst %/tests/,%,$(dir $(wildcard modules/*/tests/*.tftest.hcl projects/*/tests/*.tftest.hcl))))
PY_PROJECTS := projects/02-serverless-order-pipeline projects/04-finops-automation projects/06-gcp-gke-platform
HELM_CHARTS := projects/06-gcp-gke-platform/charts/api

.PHONY: help init lint test security fmt clean helm

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

init: ## terraform init sin backend en todas las raíces
	@for d in $(TF_DIRS); do terraform -chdir=$$d init -backend=false -input=false >/dev/null && echo "init ok: $$d"; done

fmt: ## Formatea Terraform y Python
	terraform fmt -recursive
	ruff format .

lint: init ## fmt-check, validate, tflint y ruff
	terraform fmt -check -recursive
	@for d in $(TF_DIRS); do echo "== $$d"; terraform -chdir=$$d validate -no-color || exit 1; done
	@command -v tflint >/dev/null && for d in $(TF_DIRS); do tflint --chdir=$$d --config=$(CURDIR)/.tflint.hcl || exit 1; done || echo "tflint no instalado: omitido"
	ruff check .
	ruff format --check .

test: init ## terraform test (proveedores simulados) + pytest
	@for d in $(TF_TEST_DIRS); do echo "== terraform test $$d"; terraform -chdir=$$d test || exit 1; done
	@for p in $(PY_PROJECTS); do echo "== pytest $$p"; (cd $$p && python -m pytest) || exit 1; done

helm: ## helm lint + render del chart de la plataforma GKE
	@for c in $(HELM_CHARTS); do helm lint $$c --strict && helm template test $$c --set gcpServiceAccount=x@y.iam.gserviceaccount.com >/dev/null && echo "helm ok: $$c"; done

security: ## Checkov sobre Terraform, GitHub Actions y secretos
	checkov -d . --framework terraform,github_actions,secrets --config-file .checkov.yaml

clean: ## Borra artefactos locales
	find . -type d \( -name .terraform -o -name build -o -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} +
