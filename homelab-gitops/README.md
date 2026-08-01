# homelab-gitops

Fonte da verdade do cluster K3s que roda no Proxmox. Nada é aplicado à mão
depois do bootstrap: o Argo CD lê este repositório e faz o cluster convergir
para o que está commitado aqui.

O provisionamento da infra (VMs, K3s, rede) mora em [`../k3s-proxmox-terraform`](../k3s-proxmox-terraform).
A divisão é proposital: aquele repo entrega **um cluster vazio**, este entrega
**tudo que roda dentro dele**.

## Como está organizado

```
bootstrap/            aplicado uma vez, à mão
  root.yaml           Application raiz (app-of-apps)

clusters/homelab/     o que o root.yaml gerencia
  projects/           AppProjects: fronteiras de permissão
  sets/               ApplicationSets: como um diretório vira um Application

platform/             camada de plataforma (chart upstream + values)
  argocd/             o Argo CD gerencia a si mesmo
  external-secrets/   ponte pro OpenBao
  kube-prometheus-stack/
  loki/
  alloy/

cluster-config/       configuração do cluster (manifests próprios)
  secret-stores/      ClusterSecretStore -> OpenBao

ai/                   workloads de IA
  phoenix/            observabilidade de LLM (chart)
  litellm/            gateway de LLM (manifests)

docs/                 arquitetura, bootstrap, runbook
```

### As duas convenções que valem a pena entender

Todo diretório de app carrega um arquivo de metadados, e o **nome do arquivo
diz qual é o tipo do app**:

| Arquivo | Significa | Como é renderizado |
|---|---|---|
| `release.yaml` | Chart Helm upstream | 3 sources: chart + `values.yaml` deste repo + `extra/` |
| `manifests.yaml` | Manifests nossos | 1 source: o diretório, via Kustomize |

Criar um app novo é criar um diretório com o arquivo certo dentro. Não existe
lista central de apps para editar — o ApplicationSet descobre pelo `git files`
generator. Ver `clusters/homelab/sets/`.

## Bootstrap (resumo)

O caminho completo, com o OpenBao, está em [`docs/02-bootstrap.md`](docs/02-bootstrap.md).

```bash
export KUBECONFIG=../k3s-proxmox-terraform/kubeconfig

# 1. Argo CD, com os MESMOS values que ele vai se auto-gerenciar depois
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd \
  --version 10.2.2 --namespace argocd --create-namespace \
  -f platform/argocd/values.yaml

# 2. A única coisa aplicada à mão
kubectl apply -f bootstrap/root.yaml
```

A partir daqui o cluster se monta sozinho. `make status` acompanha.

## Ajustes antes do primeiro sync

`make check-placeholders` mostra o que ainda falta.

| O quê | Onde | Estado |
|---|---|---|
| URL deste repositório | `bootstrap/root.yaml`, `clusters/homelab/sets/*`, `projects/*` | **pendente** — `github.com/albuquerquealdry/homelab-gitops` |
| IP do OpenBao | `cluster-config/secret-stores/clustersecretstore.yaml` | ✅ `10.0.0.60` (CT 200, OpenBao 2.6.1) |
| Host do Postgres | `ai/phoenix/values.yaml`, `kv/homelab/litellm` | ✅ `10.0.0.40` (CT 105, PG 18.4) |
| Domínio de acesso | IngressRoutes + `platform/argocd/values.yaml` | ✅ `*.10.0.0.180.nip.io` |

`nip.io` resolve `qualquercoisa.10.0.0.180.nip.io` para `10.0.0.180` sem você
configurar DNS nenhum — e `10.0.0.180` é justamente um dos EXTERNAL-IPs que o
Traefik já anuncia, então os IngressRoutes funcionam de primeira.

## Dimensionamento — leia antes de aplicar

O cluster atual (`terraform.tfvars`: 3 workers × 1 vCPU / 2GB / 10GB) **não
comporta esta stack**. Os PVCs sozinhos pedem 20Gi e os discos têm 10G.

```hcl
# k3s-proxmox-terraform/terraform/terraform.tfvars
worker_cpu       = 2
worker_memory    = 4096   # 6144 se for rodar tudo com folga
worker_disk_size = "60G"  # 40G é o mínimo; local-path grava no disco do nó
```

Total: 6 vCPU + 12GB RAM + 180GB de disco para os workers. As *requests*
somam ~4.2Gi; os *limits* somam ~7Gi. Com 2GB por worker os requests até
cabem, mas Prometheus, Loki e Phoenix sob carga real vão disputar memória e
o kubelet começa a despejar pod.

Se o Proxmox não tiver essa folga, corte nesta ordem: Alloy (perde logs, mantém
métricas) → Loki → kube-prometheus-stack. Phoenix e LiteLLM são o ponto da coisa.

## Documentação

| | |
|---|---|
| [01 — Arquitetura](docs/01-arquitetura.md) | Por que app-of-apps + ApplicationSet, e como a ordenação realmente funciona |
| [02 — Bootstrap](docs/02-bootstrap.md) | Do cluster vazio ao cluster completo, na ordem |
| [03 — OpenBao no Proxmox](docs/03-openbao-no-proxmox.md) | LXC, unseal, auth Kubernetes, políticas |
| [04 — Runbook](docs/04-runbook.md) | Operação do dia a dia e os erros que você vai encontrar |
