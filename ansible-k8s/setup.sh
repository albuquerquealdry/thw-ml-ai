#!/bin/bash
# ============================================================
# setup.sh - Configuração inicial: copia chave SSH para Proxmox
# ============================================================
# Esse script só precisa ser rodado UMA VEZ para configurar
# o acesso SSH ao Proxmox usando chave pública.
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROXMOX_IP="10.0.0.50"
PROXMOX_PASS="root@bee@evil0x86!"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  🔑 Setup: Copiar chave SSH para Proxmox${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if sshpass is installed
if ! command -v sshpass &> /dev/null; then
    echo -e "${YELLOW}📦 Instalando sshpass...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install hudochenkov/sshpass/sshpass
    else
        sudo apt install -y sshpass 2>/dev/null || sudo yum install -y sshpass 2>/dev/null
    fi
    echo -e "${GREEN}✅ sshpass installed${NC}"
fi

# Copy SSH key to Proxmox
echo -e "${YELLOW}📤 Copiando chave SSH para Proxmox ($PROXMOX_IP)...${NC}"

sshpass -p "$PROXMOX_PASS" ssh-copy-id -o StrictHostKeyChecking=no root@$PROXMOX_IP 2>&1

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ Chave SSH copiada com sucesso!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Agora você pode rodar o playbook sem senha:"
echo -e "  ${YELLOW}./run.sh${NC}"
echo ""