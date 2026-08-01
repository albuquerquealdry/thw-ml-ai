# Bootstrap

Do cluster vazio ao cluster completo. Roteiro linear — cada passo depende do
anterior.

## Antes de começar

- [ ] Cluster K3s de pé (`kubectl get nodes` mostra 4 Ready)
- [ ] Workers redimensionados — ver [Dimensionamento](../README.md#dimensionamento--leia-antes-de-aplicar). Com 1 vCPU / 2GB / 10GB os PVCs não cabem
- [ ] `helm` e `kubectl` na sua máquina
- [x] **Postgres — feito.** CT 105 do Proxmox (`10.0.0.40`), PostgreSQL 18.4,
      `listen_addresses = *` e `pg_hba` já liberando a rede. Bancos criados com:

```sql
-- rodado via peer auth: pct exec 105 -- su - postgres -c psql
CREATE ROLE phoenix LOGIN PASSWORD '...';
CREATE ROLE litellm LOGIN PASSWORD '...';
CREATE DATABASE phoenix OWNER phoenix;
CREATE DATABASE litellm OWNER litellm;
```

> `CREATE DATABASE ... OWNER` em vez de `GRANT ALL` + `ALTER OWNER`: no
> PostgreSQL 15+ o schema `public` pertence a `pg_database_owner`, que resolve
> para o dono do banco. Criando com `OWNER` já correto, Phoenix (Alembic) e
> LiteLLM (Prisma) conseguem criar schema no boot. `GRANT ALL PRIVILEGES ON
> DATABASE` sozinho **não** dá permissão de escrita no `public` — é a pegadinha
> mais comum de PG15+.

Conexão validada de dentro do cluster (pod → `10.0.0.40:5432`, auth OK).

---

## Passo 0 — Ajustar os placeholders

```bash
cd homelab-gitops
make check-placeholders
```

Substitua em todos os arquivos que ele listar:

| Placeholder | Troque por |
|---|---|
| `https://github.com/albuquerquealdry/thw-ml-ai.git` | A URL real deste repo |
| — | (nada pendente além da URL do repo) |

Já resolvidos: Postgres (`10.0.0.40`, CT 105) e o domínio de acesso
(`*.10.0.0.180.nip.io`, que bate com o EXTERNAL-IP do Traefik).

Depois crie o repositório e envie:

```bash
git add homelab-gitops
git commit -m "feat: estrutura gitops do homelab"
git push
```

> O Argo CD lê do **remoto**, não do disco. Nada que não estiver commitado e
> enviado existe para ele.

O repositório é **público**, então o Argo CD lê sem credencial — não é preciso
registrar repo secret nem deploy key. Se um dia virar privado, aí sim:

```bash
kubectl -n argocd create secret generic repo-thw-ml-ai \
  --from-literal=type=git \
  --from-literal=url=https://github.com/albuquerquealdry/thw-ml-ai.git \
  --from-literal=username=albuquerquealdry \
  --from-literal=password=<personal access token>
kubectl -n argocd label secret repo-thw-ml-ai \
  argocd.argoproj.io/secret-type=repository
```

---

## Passo 1 — OpenBao

Faça agora, antes do Argo CD. Sem ele, Grafana, Phoenix e LiteLLM ficam
`Degraded` esperando segredo que não chega.

Roteiro completo: [03 — OpenBao no Proxmox](03-openbao-no-proxmox.md).

O que precisa estar pronto ao final:

- [ ] Serviço de pé e **destravado** (`bao status` -> `Sealed false`)
- [ ] Mount KV v2 em `kv/`
- [ ] Segredos em `kv/homelab/{grafana,phoenix-db,litellm}`
- [ ] Política `eso-read`
- [ ] Auth `kubernetes` habilitado e role `external-secrets` criada

> A etapa 7.1 do doc do OpenBao precisa de um Secret que só existe **depois** do
> Argo CD sincronizar o `secret-stores`. É a única circularidade do processo, e
> ela se resolve sozinha: siga até o passo 3 aqui, volte e termine a seção 7,
> e o ESO reconecta no retry seguinte.

---

## Passo 2 — Argo CD

```bash
export KUBECONFIG=../k3s-proxmox-terraform/kubeconfig

helm repo add argo https://argoproj.github.io/argo-helm && helm repo update

helm upgrade --install argocd argo/argo-cd \
  --version 10.2.2 \
  --namespace argocd --create-namespace \
  -f platform/argocd/values.yaml

kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
```

> Use **este** values, não `--set`. Depois do passo 3 o Argo CD passa a se
> auto-gerenciar a partir de `platform/argocd/values.yaml`; se a instalação
> divergir, o primeiro sync reverte tudo que você tiver passado por fora.

Senha inicial:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## Passo 3 — Ligar o GitOps

```bash
kubectl apply -f bootstrap/root.yaml
```

Este é o último `kubectl apply` do processo.

Acompanhe:

```bash
watch kubectl -n argocd get applications
```

Nos primeiros minutos vários apps ficam `Degraded` ou `SyncFailed`. **É
esperado** — o `secret-stores` tenta criar um `ClusterSecretStore` antes do CRD
existir, falha, e volta no backoff. Convergência típica: 5–10 minutos.

Ordem em que as coisas aparecem:

```
argocd            Synced   (se reconhece)
external-secrets  Synced   (instala os CRDs)
secret-stores     Synced   (ClusterSecretStore -> OpenBao)
kube-prometheus-stack, loki   Synced
alloy             Synced
phoenix, litellm  Synced
```

---

## Passo 4 — Terminar a ponte com o OpenBao

Assim que o `secret-stores` sincronizar, o Secret do token reviewer existe.
Volte ao [passo 7 do doc do OpenBao](03-openbao-no-proxmox.md#7-a-ponte-autenticação-kubernetes)
e conclua.

Confirme:

```bash
kubectl get clustersecretstore openbao          # Valid
kubectl get externalsecrets -A                  # todos SecretSynced
```

Se um app continuou `Degraded` esperando segredo, force o sync:

```bash
make sync APP=litellm
```

---

## Passo 5 — Ligar os ServiceMonitors

Três charts vêm com a integração de métricas desligada, porque no primeiro
bootstrap os CRDs `ServiceMonitor` e `PodMonitor` ainda não existiam. Agora
existem — ligue e commite:

```yaml
# platform/external-secrets/values.yaml
serviceMonitor:
  enabled: true

# platform/alloy/values.yaml
serviceMonitor:
  enabled: true
```

```bash
git commit -am "feat: habilita ServiceMonitors agora que os CRDs existem"
git push
```

---

## Passo 6 — Verificar

```bash
make status
```

Acessos (sem configurar DNS — `nip.io` resolve sozinho):

| | URL | Credencial |
|---|---|---|
| Argo CD | http://argocd.10.0.0.180.nip.io | `admin` / secret inicial |
| Grafana | http://grafana.10.0.0.180.nip.io | do `kv/homelab/grafana` |
| Phoenix | http://phoenix.10.0.0.180.nip.io | sem auth (LAN-only) |
| LiteLLM | http://llm.10.0.0.180.nip.io | header `Authorization: Bearer <master-key>` |

Teste ponta a ponta — uma chamada no LiteLLM deve virar um trace no Phoenix:

```bash
MASTER_KEY=$(kubectl -n ai get secret litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

curl -s http://llm.10.0.0.180.nip.io/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"sonnet","messages":[{"role":"user","content":"diga ok"}]}' | jq -r '.choices[0].message.content'
```

Abra o Phoenix: o trace da chamada aparece com latência, tokens e custo.

---

## Passo 7 — Trocar a senha do Argo CD

```bash
argocd login argocd.10.0.0.180.nip.io --plaintext
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```
