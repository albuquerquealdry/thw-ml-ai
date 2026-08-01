# OpenBao no Proxmox

O cofre de segredos do homelab. **OpenBao** é o fork do HashiCorp Vault mantido
pela Linux Foundation, sob MPL-2.0 — livre de verdade, sem BUSL, sem tier pago.
A API é compatível com a do Vault, então o provider `vault` do External Secrets
funciona sem adaptação.

Ele roda **fora** do cluster, num LXC do Proxmox, e isso é de propósito: se o
K3s morrer inteiro, as credenciais continuam de pé num container que não depende
dele. Um cofre dentro do cluster que guarda os segredos do próprio cluster é um
ciclo que só aparece no pior momento possível.

Versão de referência: **OpenBao 2.6.1**.

---

> **Status: CT 200 criado e rodando** em `10.0.0.60`, OpenBao 2.6.1 inicializado
> e destravado, KV v2 em `kv/`, segredos e política `eso-read` gravados. Falta
> só a seção 7.2/7.3 (config do auth Kubernetes), que depende do primeiro sync
> do Argo CD. As seções abaixo ficam como referência para reconstruir.

## 1. Criar o LXC

No host Proxmox (`10.0.0.50`):

```bash
pct create 200 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname openbao \
  --cores 1 --memory 512 --swap 0 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=10.0.0.60/24,gw=10.0.0.1 \
  --nameserver 10.0.0.1 \
  --unprivileged 1 \
  --onboot 1

pct set 200 --features nesting=1   # Debian 13 traz systemd 257; sem nesting ele reclama
pct start 200
```

512MB e 4GB de disco sobram. O OpenBao com storage em arquivo e algumas dezenas
de segredos usa menos de 100MB.

> `--onboot 1` faz o container subir junto com o Proxmox. Mas o OpenBao sobe
> **selado** — ver a seção de unseal no final.

---

## 2. Instalar

Dentro do LXC:

```bash
apt update && apt install -y curl

VERSION=2.6.1
curl -fsSLO "https://github.com/openbao/openbao/releases/download/v${VERSION}/openbao_${VERSION}_linux_amd64.deb"
dpkg -i "openbao_${VERSION}_linux_amd64.deb"
```

O pacote já traz tudo: binário `bao`, usuário de serviço `openbao`, unit
systemd, e config em `/etc/openbao/openbao.hcl` com storage em arquivo apontando
para `/opt/openbao/data`.

---

## 3. Configurar o listener

O `openbao.hcl` que vem no pacote habilita **HTTPS** e espera certificados em
`/opt/openbao/tls/` — que não existem ainda. Para subir agora, troque pelo
listener HTTP (a seção *Endurecendo com TLS* no final desfaz isso):

```bash
cat > /etc/openbao/openbao.hcl <<'EOF'
ui = true

storage "file" {
  path = "/opt/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  # HTTP puro: aceitável numa VLAN de homelab, e só isso.
  # O token da ServiceAccount do ESO trafega em claro nesta porta.
  tls_disable = 1
}

# O endereço que o próprio OpenBao anuncia. Sem isto, comandos que redirecionam
# (unseal em HA, por exemplo) apontam para localhost e falham de fora.
api_addr = "http://10.0.0.60:8200"
EOF

systemctl enable --now openbao
systemctl status openbao --no-pager
```

---

## 4. Inicializar e destravar

```bash
export BAO_ADDR=http://127.0.0.1:8200

bao operator init -key-shares=3 -key-threshold=2
```

A saída traz 3 **unseal keys** e o **initial root token**.

> **Guarde isso fora deste LXC.** Gerenciador de senhas, papel no cofre, o que
> for — mas não no container, e não no mesmo lugar que o backup dele. Perder as
> unseal keys significa perder todo o conteúdo do cofre, sem recuperação.

```bash
bao operator unseal   # cole a key 1
bao operator unseal   # cole a key 2 — threshold é 2

bao login             # cole o root token
bao status            # Sealed deve estar false
```

---

## 5. Habilitar o KV e gravar os segredos

O mount se chama `kv` porque é o que o `ClusterSecretStore` espera em
`spec.provider.vault.path`.

```bash
bao secrets enable -path=kv kv-v2

bao kv put kv/homelab/grafana \
  admin-user=admin \
  admin-password="$(openssl rand -base64 24)"

bao kv put kv/homelab/phoenix-db \
  password='SENHA_DO_POSTGRES'

bao kv put kv/homelab/litellm \
  master-key="sk-$(openssl rand -hex 24)" \
  salt-key="$(openssl rand -hex 24)" \
  database-url='postgresql://litellm:SENHA@10.0.0.40:5432/litellm' \
  anthropic-api-key='sk-ant-...' \
  openai-api-key='sk-...'
```

> A `salt-key` do LiteLLM criptografa as chaves de provider guardadas no banco.
> Trocá-la depois torna ilegível tudo que já foi salvo. Defina uma vez e esqueça.

Confira: `bao kv get kv/homelab/litellm`

---

## 6. Política de leitura

```bash
bao policy write eso-read - <<'EOF'
# Só leitura, e só embaixo de homelab/. Se o ESO for comprometido, o alcance
# é exatamente este caminho — não o cofre inteiro.
path "kv/data/homelab/*" {
  capabilities = ["read"]
}

# O KV v2 separa dados de metadados; o ESO precisa dos dois para resolver
# um `property` dentro de um segredo.
path "kv/metadata/homelab/*" {
  capabilities = ["read", "list"]
}
EOF
```

---

## 7. A ponte: autenticação Kubernetes

Esta é a parte que costuma dar trabalho, então vale entender o desenho antes de
copiar comandos:

```
ESO (pod no cluster)
  │ 1. pede um token da própria ServiceAccount `external-secrets`
  │ 2. manda esse token pro OpenBao
  ▼
OpenBao (LXC, fora do cluster)
  │ 3. precisa saber se o token é legítimo — mas não é um pod, então não tem
  │    como perguntar "de dentro". Ele chama a API do Kubernetes de fora,
  │    autenticando com as credenciais da SA `openbao-token-reviewer`.
  ▼
API do Kubernetes
      4. responde: "esse token é da SA external-secrets, namespace
         external-secrets" -> OpenBao emite um token com a policy eso-read
```

Nenhuma senha estática nesse caminho. A SA `openbao-token-reviewer` e seu
ClusterRoleBinding já estão versionados em
`cluster-config/secret-stores/token-reviewer.yaml`, com a permissão mínima
(`system:auth-delegator` — só cria TokenReview).

### 7.1 Extrair as credenciais do cluster

Na sua máquina, com o `KUBECONFIG` apontando pro K3s:

```bash
kubectl -n external-secrets get secret openbao-token-reviewer \
  -o jsonpath='{.data.token}' | base64 -d > /tmp/reviewer.jwt

kubectl -n external-secrets get secret openbao-token-reviewer \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/k8s-ca.crt

scp /tmp/reviewer.jwt /tmp/k8s-ca.crt root@10.0.0.60:/tmp/
```

> Se o Secret estiver vazio, o `secret-stores` ainda não sincronizou. Aplique-o
> primeiro (ele está na wave `-5`) e espere o control plane preencher o token.

### 7.2 Configurar no OpenBao

```bash
bao auth enable kubernetes

bao write auth/kubernetes/config \
  kubernetes_host="https://10.0.0.180:6443" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  token_reviewer_jwt=@/tmp/reviewer.jwt \
  disable_local_ca_jwt=true
```

> `disable_local_ca_jwt=true` é obrigatório aqui. Por padrão o método assume que
> está rodando **dentro** de um pod e tenta ler o CA e o token de
> `/var/run/secrets/kubernetes.io/serviceaccount/`. Fora do cluster esse caminho
> não existe e a config falha de um jeito pouco óbvio.

### 7.3 Amarrar SA -> política

```bash
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read \
  ttl=1h

rm -f /tmp/reviewer.jwt /tmp/k8s-ca.crt
```

O nome `external-secrets` da role é o que aparece em
`cluster-config/secret-stores/clustersecretstore.yaml`.

---

## 8. Validar

Do lado do cluster:

```bash
kubectl get clustersecretstore openbao
# STATUS deve ser Valid

kubectl -n ai get externalsecret litellm
# STATUS SecretSynced, READY True

kubectl -n ai get secret litellm -o jsonpath='{.data}' | jq 'keys'
# ["ANTHROPIC_API_KEY","DATABASE_URL","LITELLM_MASTER_KEY",...]
```

Se travar, o log do ESO diz exatamente o que o OpenBao respondeu:

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=50
```

| Erro | Causa quase sempre |
|---|---|
| `permission denied` | A role não existe, ou `bound_service_account_*` não bate |
| `connection refused` | OpenBao selado (após reboot) ou IP errado no ClusterSecretStore |
| `service account name not authorized` | ESO instalado em outro namespace que não `external-secrets` |
| `local JWT not found` | Faltou `disable_local_ca_jwt=true` |

---

## 9. Unseal depois de reboot

Este é o custo real do Shamir: **todo restart do LXC deixa o OpenBao selado**, e
enquanto isso o ESO não consegue ler nada. Segredos já materializados continuam
no cluster (o ESO não apaga o que não consegue renovar), então nada cai na hora
— mas nenhum segredo novo aparece e nenhuma rotação acontece.

```bash
pct enter 200
export BAO_ADDR=http://127.0.0.1:8200
bao operator unseal   # 2 vezes, com 2 das 3 keys
```

As alternativas, e por que não estão aqui:

- **Auto-unseal via transit** — um segundo OpenBao guarda a chave do primeiro.
  Funciona e é o caminho "certo", mas move o problema: alguém tem que destravar
  o segundo. Só compensa se o segundo já existir por outro motivo.
- **Auto-unseal via KMS de nuvem** — resolve de verdade, e cria dependência de
  um provedor externo. Vai contra o motivo de ter o cofre em casa.
- **Unseal keys num script no boot** — deixa a chave do cofre ao lado do cofre.
  Não é criptografia, é teatro.

Para um homelab, destravar à mão depois de um reboot planejado é o trade-off
honesto. O que **não** vale é esquecer que isso existe: coloque no runbook.

---

## Endurecendo com TLS

O HTTP puro da seção 3 expõe o token da ServiceAccount do ESO em claro na LAN.
Para uma VLAN doméstica isolada é um risco aceitável; se a rede é compartilhada,
não é.

No LXC:

```bash
mkdir -p /opt/openbao/tls && cd /opt/openbao/tls
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=openbao.lab" \
  -addext "subjectAltName=IP:10.0.0.60,DNS:openbao.lab"
chown -R openbao:openbao /opt/openbao/tls
chmod 600 tls.key
```

Restaure o listener HTTPS original em `/etc/openbao/openbao.hcl` (os caminhos
já batem com os do pacote), ajuste `api_addr` para `https://10.0.0.60:8200` e
reinicie.

No cluster, o certificado é autoassinado, então o ESO precisa da CA. Adicione um
ConfigMap com o `tls.crt` e aponte o store para ele:

```yaml
# cluster-config/secret-stores/clustersecretstore.yaml
spec:
  provider:
    vault:
      server: https://10.0.0.60:8200
      caProvider:
        type: ConfigMap
        name: openbao-ca
        key: ca.crt
        namespace: external-secrets
```

```bash
kubectl -n external-secrets create configmap openbao-ca --from-file=ca.crt=tls.crt \
  --dry-run=client -o yaml > cluster-config/secret-stores/openbao-ca.yaml
# adicione o arquivo ao kustomization.yaml e commite
```

---

## Backup

O storage em arquivo é um diretório. Com o serviço parado, um tar resolve:

```bash
systemctl stop openbao
tar czf /root/openbao-$(date +%F).tar.gz /opt/openbao/data /etc/openbao
systemctl start openbao   # lembre de destravar
```

Ou, mais simples, use o backup do próprio Proxmox no CT 200 — ele já congela o
container. **O backup não substitui as unseal keys**: um snapshot dos dados sem
as chaves é um blob criptografado e inútil.
