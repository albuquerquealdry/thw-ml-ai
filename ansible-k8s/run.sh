#!/bin/bash
# ============================================================
# run.sh - Complete Kubernetes Cluster Setup
# ============================================================
# This script:
#   1. Installs Ansible (if needed)
#   2. Copies SSH key to Proxmox (if needed)
#   3. Provisions VMs on Proxmox
#   4. Installs Kubernetes on the VMs
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
echo -e "${BLUE}  🚀 Kubernetes Cluster Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ============================================================
# Step 0: Install Ansible if needed
# ============================================================
if ! command -v ansible-playbook &> /dev/null; then
    echo -e "${YELLOW}📦 Installing Ansible...${NC}"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install ansible
        else
            echo -e "${RED}Homebrew not found. Install it first: https://brew.sh${NC}"
            exit 1
        fi
    elif command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y ansible
    elif command -v yum &> /dev/null; then
        sudo yum install -y ansible
    else
        echo -e "${RED}Could not install Ansible automatically. Install it manually.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✅ Ansible is installed${NC}"
echo ""

# ============================================================
# Step 1: Install sshpass and copy SSH key to Proxmox
# ============================================================
echo -e "${YELLOW}[STEP 1/3] Configuring SSH access to Proxmox...${NC}"
echo -e "${YELLOW}----------------------------------------${NC}"

if ! command -v sshpass &> /dev/null; then
    echo -e "${YELLOW}📦 Installing sshpass...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install hudochenkov/sshpass/sshpass
    else
        sudo apt install -y sshpass 2>/dev/null || sudo yum install -y sshpass 2>/dev/null
    fi
fi

# Test if SSH key already works
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@$PROXMOX_IP "echo ok" 2>/dev/null | grep -q "ok"; then
    echo -e "${GREEN}✅ SSH key already configured for Proxmox${NC}"
else
    echo -e "${YELLOW}📤 Copying SSH key to Proxmox ($PROXMOX_IP)...${NC}"
    sshpass -p "$PROXMOX_PASS" ssh-copy-id -o StrictHostKeyChecking=no root@$PROXMOX_IP 2>&1
    echo -e "${GREEN}✅ SSH key copied to Proxmox${NC}"
fi
echo ""

# ============================================================
# Step 2: Provision VMs on Proxmox
# ============================================================
echo -e "${YELLOW}[STEP 2/3] Provisioning VMs on Proxmox...${NC}"
echo -e "${YELLOW}----------------------------------------${NC}"

ansible-playbook -i inventory/proxmox.ini provision.yml

echo ""
echo -e "${GREEN}✅ VMs provisioned successfully!${NC}"
echo ""

# ============================================================
# Step 3: Install Kubernetes
# ============================================================
echo -e "${YELLOW}[STEP 3/3] Installing Kubernetes on the VMs...${NC}"
echo -e "${YELLOW}----------------------------------------${NC}"

# Wait for cloud-init to finish
echo "⏳ Waiting 30 seconds for cloud-init to complete..."
sleep 30

ansible-playbook -i inventory/hosts.ini site.yml

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ Cluster Kubernetes pronto!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  📌 Control Plane: ${BLUE}10.0.0.100${NC}"
echo -e "  📌 Worker:        ${BLUE}10.0.0.101${NC}"
echo ""
echo -e "  🔑 SSH Access:"
echo -e "     ${YELLOW}ssh root@10.0.0.100${NC}"
echo -e "     ${YELLOW}ssh root@10.0.0.101${NC}"
echo ""
echo -e "  📦 Kubectl (no master):"
echo -e "     ${YELLOW}kubectl get nodes${NC}"
echo -e "     ${YELLOW}kubectl get pods -A${NC}"
echo ""
echo -e "  🔄 Para adicionar mais workers manualmente:"
echo -e "     ${YELLOW}ssh root@10.0.0.100 'cat /root/kubeadm_join_command.txt'${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"