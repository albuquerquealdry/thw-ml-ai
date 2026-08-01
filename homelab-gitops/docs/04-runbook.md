# Runbook

## Tarefas do dia a dia

### Adicionar um app baseado em chart Helm

```bash
mkdir -p platform/cert-manager/extra

cat > platform/cert-manager/release.yaml <<'EOF'
name: cert-manager
namespace: cert-manager
project: platform
syncWave: "0"
chart:
  repo: https://charts.jetstack.io
  name: cert-manager
  version: 1.19.2
EOF

cat > platform/cert-manager/values.yaml <<'EOF'
crds:
  enabled: true
EOF

printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
  > platform/cert-manager/extra/kustomization.yaml
```

Adicione o repo do chart ao `sourceRepos` do AppProject correspondente
(`clusters/homelab/projects/platform.yaml`) — senão o sync é recusado com
`application repo ... is not permitted`.

Commite. O ApplicationSet cria o Application sozinho.

> Os três arquivos são obrigatórios. `missingkey=error` faz o ApplicationSet
> falhar alto se faltar campo no `release.yaml`, e o `extra/` precisa existir
> mesmo vazio porque é uma das três sources do template.

### Adicionar um app de manifests próprios

```bash
mkdir -p workloads/meuapp
cat > workloads/meuapp/manifests.yaml <<'EOF'
name: meuapp
namespace: meuapp
project: ai
syncWave: "30"
EOF
# + kustomization.yaml e os manifests
```

Se a camada for nova (`workloads/`, aqui), acrescente o path ao generator em
`clusters/homelab/sets/kustomize.yaml`.

### Subir a versão de um chart

Edite `version` no `release.yaml` e commite. O Argo CD detecta em até 3 minutos.

Para ver o que muda antes:

```bash
make diff APP=loki
```

### Adicionar um modelo ao LiteLLM

Edite `ai/litellm/config.yaml`, commite. O `configMapGenerator` do Kustomize
gera um nome novo (hash do conteúdo), o pod spec muda, e o rollout acontece
sozinho — sem `kubectl rollout restart`.

Se o modelo precisar de uma chave nova:

```bash
# no LXC do OpenBao
bao kv patch kv/homelab/litellm groq-api-key='gsk_...'
```

Depois acrescente a entrada em `ai/litellm/externalsecret.yaml`:

```yaml
    - secretKey: GROQ_API_KEY
      remoteRef: {key: homelab/litellm, property: groq-api-key}
```

### Rotacionar um segredo

Escreva o valor novo no OpenBao. O ESO reconcilia no `refreshInterval` (1h) ou
imediatamente com:

```bash
kubectl -n ai annotate externalsecret litellm force-sync="$(date +%s)" --overwrite
```

O Secret é atualizado, mas **pods já rodando não releem `envFrom`**. Reinicie:

```bash
kubectl -n ai rollout restart deploy/litellm
```

---

## Diagnóstico

### App preso em `Degraded` / `SyncFailed`

```bash
kubectl -n argocd get application <app> -o jsonpath='{.status.conditions}' | jq
kubectl -n argocd get application <app> -o jsonpath='{.status.operationState.message}'
```

Nos primeiros 10 minutos após o bootstrap isso é normal — o retry resolve. Fora
disso, os culpados de sempre:

| Sintoma | Causa | Correção |
|---|---|---|
| `no matches for kind "ExternalSecret"` | ESO ainda não instalou os CRDs | Esperar o retry; se persistir, `make sync APP=external-secrets` |
| `application repo X is not permitted` | Repo do chart fora do `sourceRepos` do AppProject | Adicionar em `clusters/homelab/projects/*.yaml` |
| `is not permitted in project` (recurso) | AppProject `ai` bloqueando recurso cluster-scoped | Correto por design — mova o app para `platform` só se realmente precisar |
| `rpc error ... 401` no repo-server | Repo privado sem credencial | Ver [passo 0 do bootstrap](02-bootstrap.md#passo-0--ajustar-os-placeholders) |
| `OCI registry ... unauthorized` no Phoenix | Repo OCI não declarado | `configs.repositories` em `platform/argocd/values.yaml` |

### `ExternalSecret` não sincroniza

```bash
kubectl -n ai describe externalsecret litellm
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=50
```

A causa mais comum, de longe: **OpenBao selado após reboot**.

```bash
ssh root@10.0.0.50 "pct exec 200 -- env BAO_ADDR=http://127.0.0.1:8200 bao status"
```

`Sealed: true` -> destravar ([seção 9](03-openbao-no-proxmox.md#9-unseal-depois-de-reboot)).

Tabela de erros do ESO na [seção 8](03-openbao-no-proxmox.md#8-validar).

### App em `OutOfSync` que nunca estabiliza

Algo no cluster está reescrevendo um campo que o Argo considera drift. Veja o
que:

```bash
argocd app diff <app>
```

Se for campo mutado por controller (caBundle de webhook, token de SA), a saída é
um `ignoreDifferences` no template do ApplicationSet correspondente —
`clusters/homelab/sets/helm.yaml` já traz dois exemplos.

### Pod sendo despejado / OOMKilled

Quase sempre é o dimensionamento.

```bash
kubectl top nodes
kubectl get events -A --field-selector reason=Evicted
kubectl describe node <nó> | grep -A8 "Allocated resources"
```

Se `memory requests` passa de ~85% da alocável, o cluster está no limite — ver
[Dimensionamento](../README.md#dimensionamento--leia-antes-de-aplicar).

### PVC `Pending`

`local-path` grava no disco do nó. `Pending` significa disco cheio ou
StorageClass errada.

```bash
kubectl get pvc -A
kubectl describe pvc <pvc> -n <ns>
ssh ubuntu@10.0.0.185 "df -h /var/lib/rancher/k3s/storage"
```

> **`local-path` prende o pod ao nó.** O volume mora no disco de um worker
> específico; se esse nó cair, o pod não é reagendado — ele fica `Pending` até o
> nó voltar. Para Prometheus e Loki num homelab isso é aceitável. Se deixar de
> ser, a resposta é Longhorn.

---

## Recuperação

### Argo CD quebrado por um values ruim

Se o `argocd-server` ou o application-controller não sobem, ninguém aplica a
correção. Saída manual:

```bash
git revert <commit>   # ou corrija platform/argocd/values.yaml
helm upgrade argocd argo/argo-cd --version 10.2.2 \
  -n argocd -f platform/argocd/values.yaml
```

O Argo volta e retoma a auto-gestão. Este é o risco conhecido do
auto-gerenciamento — a saída é sempre `helm upgrade` com o values corrigido.

### Reconstruir o cluster do zero

Terraform destrói e recria as VMs; este repositório recria tudo que roda dentro.
O que **não** volta sozinho:

- Conteúdo do OpenBao (LXC separado, não é tocado)
- Bancos do Phoenix e do LiteLLM (Postgres no Proxmox, também não é tocado)
- PVCs do Prometheus e do Loki — métricas e logs históricos **são perdidos**

Ou seja: estado que importa está fora do cluster de propósito. O cluster é
descartável, e é isso que torna a reconstrução um procedimento de rotina em vez
de um evento.

```bash
cd ../k3s-proxmox-terraform && ./deploy.sh
cd ../homelab-gitops
# passos 2 e 3 do bootstrap; o resto converge sozinho
```

### Voltar um app para uma versão anterior

```bash
argocd app history <app>
argocd app rollback <app> <id>
```

Isso é uma medida de emergência: o Argo volta o estado, mas o Git continua na
versão nova, e o próximo reconcile puxa de volta. **Reverta o commit também.**

---

## Manutenção periódica

| Quando | O quê |
|---|---|
| Após reboot do Proxmox | Destravar o OpenBao |
| Mensal | Bump dos charts (`version` nos `release.yaml`), com `make diff` antes |
| Mensal | `pct backup` do CT 200 (OpenBao) |
| Trimestral | Rotacionar as chaves de provider do LiteLLM |
| Quando o K3s subir de versão | Conferir compatibilidade dos CRDs antes do upgrade |
