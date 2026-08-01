# Arquitetura

## O fluxo, inteiro

```
 você ──commit──> GitHub ──poll (3min)──> Argo CD ──apply──> cluster K3s
                                             │
                                             └── ESO ──token da SA──> OpenBao (LXC no Proxmox)
                                                    <──segredo──
```

Só existe um caminho de escrita para o cluster: um commit neste repositório.
`kubectl apply` continua funcionando — e o `selfHeal: true` desfaz em até
3 minutos. Isso é o comportamento desejado, não um efeito colateral.

## Camadas

```
bootstrap/root.yaml            (Application, aplicado à mão — 1 vez)
      │
      └── clusters/homelab/    (Kustomize: AppProjects + ApplicationSets)
             │
             ├── AppProject platform   ─ pode mexer em recursos cluster-scoped
             ├── AppProject ai         ─ preso ao namespace `ai`
             │
             ├── ApplicationSet helm       ─ varre platform/*/release.yaml
             │                               e ai/*/release.yaml
             └── ApplicationSet kustomize  ─ varre cluster-config/*/manifests.yaml
                                             e ai/*/manifests.yaml
```

O `root` é a única coisa aplicada à mão. Ele gerencia os AppProjects e os
ApplicationSets; os ApplicationSets geram os Applications; os Applications
sincronizam os workloads.

## As decisões que importam

### Por que ApplicationSet e não app-of-apps puro

Com app-of-apps, cada app novo exige criar um `Application` e adicioná-lo a um
`kustomization.yaml`. Dois arquivos, um deles central — que vira ponto de
conflito de merge e de esquecimento.

Com o `git files` generator, o app é descoberto pelo arquivo de metadados que
mora junto dele. Um diretório novo = um app novo. Nada central para editar.

O custo: os parâmetros vêm de um arquivo de convenção (`release.yaml` /
`manifests.yaml`) em vez do schema do `Application`, então `goTemplateOptions:
[missingkey=error]` está ligado — se você esquecer um campo, o ApplicationSet
falha na hora em vez de gerar um Application meio pronto.

### Por que 3 sources nos apps Helm

```yaml
sources:
  - repoURL: <chart repo>          # o chart upstream, nunca forkado
    chart: <nome>
    helm.valueFiles: [$values/platform/loki/values.yaml]
  - repoURL: <este repo>           # ref: values -> resolve o $values acima
    ref: values
  - repoURL: <este repo>           # extra/ -> ExternalSecret, IngressRoute...
    path: platform/loki/extra
```

A alternativa comum é o *umbrella chart*: um `Chart.yaml` local com o upstream
como dependência. Rejeitada porque o Argo CD roda `helm dependency build`, que
exige um `Chart.lock` versionado — que precisa ser regerado à mão a cada bump.
Multi-source não precisa de lock nenhum.

O `extra/` existe em **todo** app Helm, mesmo vazio (`resources: []`). É um
pouquinho de boilerplate em troca de um template uniforme, sem condicionais.

### Como a ordenação realmente funciona (e como não funciona)

Cada Application gerado leva uma annotation `argocd.argoproj.io/sync-wave`, mas
**sync-waves não ordenam Applications criados por um ApplicationSet** — waves
só ordenam recursos dentro de uma mesma operação de sync, e o
applicationset-controller cria cada Application direto, fora de um sync pai.

As waves estão lá para documentar a intenção e para leitura na UI. **A
convergência de verdade vem do retry:**

```yaml
retry:
  limit: 10
  backoff: {duration: 15s, factor: 2, maxDuration: 5m}
```

Na prática: o `secret-stores` tenta criar um `ClusterSecretStore` antes do CRD
existir, falha, espera 15s, tenta de novo. Enquanto isso o `external-secrets`
instalou o CRD. Na terceira tentativa passa. O cluster inteiro converge em
5–10 minutos sem ninguém orquestrar nada.

Isso é aceitável em homelab e é o padrão da maioria das instalações Argo CD.
Se um dia a ordenação precisar ser garantida, o caminho é *progressive syncs*
no ApplicationSet — que exige ligar uma feature flag no controller.

### Por que o Argo CD se auto-gerencia

`platform/argocd/` faz o Argo CD ser um Application como qualquer outro. O
ganho é que upgrade vira bump de versão num commit, com histórico e rollback.

O risco é real e vale saber: um values quebrado pode derrubar o próprio
controller que aplicaria a correção. A saída é sempre a mesma — `helm upgrade`
manual com o values corrigido, e o Argo volta a se auto-gerenciar. Por isso o
`helm install` do bootstrap usa **exatamente o mesmo arquivo** que o Application
usa: se divergirem, o primeiro sync reverte a instalação.

### Por que os AppProjects são dois

`platform` pode criar qualquer coisa, inclusive CRDs e ClusterRoles — é o que
os charts de plataforma precisam.

`ai` tem `clusterResourceWhitelist: []` e destino travado no namespace `ai`.
Se um chart de LLM um dia trouxer um ClusterRoleBinding, o sync **falha** em vez
de aplicar silenciosamente. Isso é a fronteira valendo dinheiro: workload de IA
executa código e prompt de terceiros, e não tem motivo pra tocar em nada
cluster-scoped.

## Segredos

```
Git                     OpenBao (LXC no Proxmox)        Cluster
────────────────────────────────────────────────────────────────
ExternalSecret    ──referencia──> kv/homelab/litellm
(caminho, sem valor)                    │
                                        │ ESO autentica com token da
                                        │ própria ServiceAccount
                                        ▼
                                   Secret litellm  ──envFrom──> pod
```

O que está versionado é o **caminho** do segredo. O valor nunca entra no Git,
nem criptografado. E o cofre fica **fora** do cluster de propósito: se o K3s
morrer inteiro, as credenciais continuam num LXC que não depende dele.

Não há credencial estática na ponte. O ESO manda o token da própria
ServiceAccount, e o OpenBao valida esse token contra a API do Kubernetes usando
a ServiceAccount `openbao-token-reviewer` (permissão exata: criar TokenReview).
Detalhes em [03 — OpenBao no Proxmox](03-openbao-no-proxmox.md).

## Observabilidade

```
pods ──logs──> Alloy (DaemonSet) ──push──> Loki ──┐
                                                   ├──> Grafana
nós/pods ──scrape──> Prometheus ──────────────────┘

apps LLM ──OpenAI API──> LiteLLM ──OTLP──> Phoenix (traces, evals)
```

Duas camadas de propósito. Prometheus e Loki respondem "o cluster está de pé".
Phoenix responde "o que o modelo respondeu, quanto custou, quanto demorou" —
questões que métrica de infra não alcança.

O LiteLLM é o que liga as duas: todo app fala com ele usando o SDK da OpenAI, e
ele emite trace OTLP pro Phoenix em toda chamada. Trocar de modelo vira editar
`ai/litellm/config.yaml`, sem tocar em código de aplicação.
