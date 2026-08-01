SHELL := /bin/bash
.DEFAULT_GOAL := help

ARGOCD_NS ?= argocd

# Os valores que precisam virar os do seu ambiente antes do primeiro sync.
PLACEHOLDERS := albuquerquealdry/homelab-gitops

.PHONY: help
help: ## Lista os alvos
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: check-placeholders
check-placeholders: ## Mostra onde os valores de exemplo ainda aparecem
	@for p in $(PLACEHOLDERS); do \
	  echo "── $$p"; \
	  grep -rn --include='*.yaml' --include='*.md' -E "$$p" . || echo "   (nenhuma ocorrência)"; \
	done

.PHONY: lint
lint: ## Renderiza todo Kustomize e valida o YAML dos apps Helm
	@fail=0; \
	for k in $$(find . -name kustomization.yaml -not -path './.git/*'); do \
	  d=$$(dirname $$k); \
	  if ! kubectl kustomize "$$d" > /dev/null; then echo "FALHOU: $$d"; fail=1; fi; \
	done; \
	if python3 -c 'import yaml' 2>/dev/null; then \
	  for f in $$(find . \( -name 'release.yaml' -o -name 'manifests.yaml' -o -name 'values.yaml' \) -not -path './.git/*'); do \
	    python3 -c "import sys,yaml;yaml.safe_load(open(sys.argv[1]))" "$$f" \
	      || { echo "YAML inválido: $$f"; fail=1; }; \
	  done; \
	else \
	  echo "(pyyaml ausente — pulando a checagem dos values/release; a CI faz)"; \
	fi; \
	[ $$fail -eq 0 ] && echo "ok" || exit 1

.PHONY: contract
contract: ## Confere que todo app tem os arquivos que o ApplicationSet espera
	@fail=0; \
	for r in $$(find platform ai -name release.yaml 2>/dev/null); do \
	  d=$$(dirname $$r); \
	  [ -f "$$d/values.yaml" ] || { echo "falta $$d/values.yaml"; fail=1; }; \
	  [ -f "$$d/extra/kustomization.yaml" ] || { echo "falta $$d/extra/kustomization.yaml"; fail=1; }; \
	done; \
	for m in $$(find cluster-config ai -name manifests.yaml 2>/dev/null); do \
	  d=$$(dirname $$m); \
	  [ -f "$$d/kustomization.yaml" ] || { echo "falta $$d/kustomization.yaml"; fail=1; }; \
	done; \
	[ $$fail -eq 0 ] && echo "ok" || exit 1

.PHONY: status
status: ## Estado dos Applications, ExternalSecrets e pods
	@kubectl -n $(ARGOCD_NS) get applications \
	  -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
	@echo; kubectl get externalsecrets -A 2>/dev/null || echo "(CRD ExternalSecret ainda não existe)"
	@echo; kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null

.PHONY: sync
sync: ## Força o sync de um app — make sync APP=litellm
	@test -n "$(APP)" || { echo "uso: make sync APP=<nome>"; exit 1; }
	argocd app sync $(APP)

.PHONY: diff
diff: ## Diff entre Git e cluster — make diff APP=loki
	@test -n "$(APP)" || { echo "uso: make diff APP=<nome>"; exit 1; }
	argocd app diff $(APP)

.PHONY: bootstrap
bootstrap: ## Instala o Argo CD e aplica o Application raiz
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd --version 10.2.2 \
	  --namespace $(ARGOCD_NS) --create-namespace \
	  -f platform/argocd/values.yaml
	kubectl -n $(ARGOCD_NS) rollout status deploy/argocd-server --timeout=5m
	kubectl apply -f bootstrap/root.yaml

.PHONY: password
password: ## Senha inicial do admin do Argo CD
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo
