#!/usr/bin/env bash
# Ubuntu server setup script — run with: curl -fsSL https://raw.githubusercontent.com/valdecircarvalho/infra-ovh/main/setup.sh | sudo bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/valdecircarvalho/infra-ovh/main"
ADMIN_USER="valdecir"
LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%T)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute com sudo: curl -fsSL ... | sudo bash"

# ─────────────────────────────────────────────
setup_packages() {
    log "Instalando pacotes essenciais..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -yq \
        git curl wget unzip zip rsync \
        net-tools iputils-ping dnsutils nmap traceroute tcpdump \
        vim nano tmux \
        htop ncdu iotop lsof sysstat \
        jq tree \
        ca-certificates gnupg software-properties-common apt-transport-https \
        build-essential python3 python3-pip \
        cloud-guest-utils lvm2 parted \
        unattended-upgrades fail2ban
    ok "Pacotes instalados"
}

# ─────────────────────────────────────────────
setup_user() {
    log "Configurando usuário $ADMIN_USER..."
    if ! id -u "$ADMIN_USER" &>/dev/null; then
        useradd -m -s /bin/bash -c "Valdecir Carvalho" "$ADMIN_USER"
        ok "Usuário $ADMIN_USER criado"
    else
        ok "Usuário $ADMIN_USER já existe"
    fi

    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${ADMIN_USER}"
    chmod 440 "/etc/sudoers.d/${ADMIN_USER}"
    ok "sudo sem senha configurado para $ADMIN_USER"

    usermod -aG sudo,adm,systemd-journal "$ADMIN_USER" 2>/dev/null || true
}

# ─────────────────────────────────────────────
setup_ssh_key() {
    log "Configurando chave SSH..."

    local KEY_CONTENT
    KEY_CONTENT=$(curl -fsSL "${REPO_RAW}/keys/authorized_keys") \
        || die "Falha ao baixar keys/authorized_keys do repositório"

    echo "$KEY_CONTENT" | grep -qE '^ssh-' \
        || die "Arquivo keys/authorized_keys não contém uma chave SSH válida (deve começar com ssh-)"

    add_keys_to() {
        local auth_file="$1"
        while IFS= read -r line; do
            [[ "$line" =~ ^ssh- ]] || continue
            grep -qxF "$line" "$auth_file" 2>/dev/null || echo "$line" >> "$auth_file"
        done <<< "$KEY_CONTENT"
    }

    # Adiciona para root
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    add_keys_to /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    ok "Chave SSH configurada para root"

    # Adiciona para o usuário admin
    local USER_SSH="/home/${ADMIN_USER}/.ssh"
    mkdir -p "$USER_SSH" && chmod 700 "$USER_SSH"
    touch "${USER_SSH}/authorized_keys"
    add_keys_to "${USER_SSH}/authorized_keys"
    chmod 600 "${USER_SSH}/authorized_keys"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "$USER_SSH"
    ok "Chave SSH configurada para $ADMIN_USER"
}

# ─────────────────────────────────────────────
setup_timezone() {
    log "Configurando timezone..."
    timedatectl set-timezone America/Sao_Paulo
    ok "Timezone: $(timedatectl | grep 'Time zone' | awk '{print $3}')"
}

# ─────────────────────────────────────────────
setup_disk_expand() {
    log "Verificando expansão de disco (LVM)..."

    ROOT_DEV=$(df / | tail -1 | awk '{print $1}')

    # Confirma que é LVM
    if ! lvdisplay "$ROOT_DEV" &>/dev/null; then
        warn "Disco root $ROOT_DEV não é LVM — expansão ignorada"
        return 0
    fi

    # Descobre PV que sustenta este LV
    VG_NAME=$(lvdisplay "$ROOT_DEV" | awk '/VG Name/{print $3}')
    PV_DEV=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
              | awk -v vg="$VG_NAME" '$2==vg{print $1}' | head -1)

    [[ -n "$PV_DEV" ]] || { warn "PV não encontrado para VG $VG_NAME"; return 0; }

    # Extrai disco base e número da partição
    if   [[ "$PV_DEV" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        DISK="${BASH_REMATCH[1]}"; PART_NUM="${BASH_REMATCH[2]}"
    elif [[ "$PV_DEV" =~ ^(/dev/[a-z]+)([0-9]+)$              ]]; then
        DISK="${BASH_REMATCH[1]}"; PART_NUM="${BASH_REMATCH[2]}"
    else
        warn "Formato de dispositivo não reconhecido: $PV_DEV"; return 0
    fi

    # Força o kernel a re-ler o tamanho do disco (ESXi hot-extend)
    # Método 1: rescan do dispositivo específico
    local SCSI_DEV
    SCSI_DEV=$(basename "$DISK")
    [[ -f "/sys/class/block/${SCSI_DEV}/device/rescan" ]] && \
        echo 1 > "/sys/class/block/${SCSI_DEV}/device/rescan"

    # Método 2: rescan de todos os hosts SCSI (mais confiável no ESXi)
    for h in /sys/class/scsi_host/*/scan; do
        echo "- - -" > "$h" 2>/dev/null || true
    done
    sleep 3
    ok "Rescan SCSI concluído"

    # Valida se há espaço para expandir antes de alterar qualquer coisa
    if ! growpart --dry-run "$DISK" "$PART_NUM" &>/dev/null; then
        ok "Disco já no tamanho máximo — nenhuma alteração necessária"
        df -h /
        return 0
    fi
    log "Espaço disponível detectado — prosseguindo com a expansão"

    # 1 — Expande a partição
    growpart "$DISK" "$PART_NUM" && ok "Partição ${DISK}${PART_NUM} expandida"

    # 2 — Atualiza o PV para enxergar o novo tamanho
    pvresize "$PV_DEV" && ok "PV $PV_DEV redimensionado"

    # 3 — Estende o LV com todo o espaço livre disponível
    lvextend -l +100%FREE "$ROOT_DEV" && ok "LV $ROOT_DEV expandido"

    # 4 — Expande o filesystem
    local FS_TYPE
    FS_TYPE=$(df -T / | tail -1 | awk '{print $2}')
    case "$FS_TYPE" in
        ext4|ext3) resize2fs "$ROOT_DEV" && ok "Filesystem $FS_TYPE expandido" ;;
        xfs)       xfs_growfs /          && ok "Filesystem XFS expandido"       ;;
        *)         warn "Tipo de filesystem desconhecido: $FS_TYPE — expanda manualmente" ;;
    esac

    log "Disco após expansão:"
    df -h /
}

# ─────────────────────────────────────────────
setup_git() {
    log "Configurando git para $ADMIN_USER..."
    sudo -u "$ADMIN_USER" git config --global user.name  "Valdecir Carvalho"
    sudo -u "$ADMIN_USER" git config --global user.email "valdecir.carvalho@outlook.com"
    sudo -u "$ADMIN_USER" git config --global init.defaultBranch main
    sudo -u "$ADMIN_USER" git config --global pull.rebase false
    sudo -u "$ADMIN_USER" git config --global core.editor nano
    ok "Git configurado (user: Valdecir Carvalho <vcarvalho@vertigo.com.br>)"
}

# ─────────────────────────────────────────────
setup_docker() {
    log "Instalando Docker..."

    if command -v docker &>/dev/null; then
        ok "Docker já instalado: $(docker --version)"
    else
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -q
        apt-get install -yq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin

        systemctl enable docker && systemctl start docker
        ok "Docker instalado: $(docker --version)"
    fi

    for u in "$ADMIN_USER" administrator; do
        id -u "$u" &>/dev/null && usermod -aG docker "$u" \
            && ok "$u adicionado ao grupo docker" || true
    done
}

# ─────────────────────────────────────────────
setup_swap() {
    log "Verificando swap..."
    if swapon --show | grep -q .; then
        ok "Swap já existe: $(free -h | awk '/Swap/{print $2}')"
        return 0
    fi

    local RAM_MB SWAP_SIZE
    RAM_MB=$(free -m | awk '/Mem:/{print $2}')
    if   [[ $RAM_MB -le 2048  ]]; then SWAP_SIZE="${RAM_MB}M"    # ≤ 2 GB RAM → swap = RAM
    elif [[ $RAM_MB -le 8192  ]]; then SWAP_SIZE="2G"            # 2–8 GB RAM → 2 GB
    elif [[ $RAM_MB -le 32768 ]]; then SWAP_SIZE="4G"            # 8–32 GB RAM → 4 GB
    else                               SWAP_SIZE="8G"            # > 32 GB RAM → 8 GB
    fi

    log "RAM: ${RAM_MB} MB → swap calculado: ${SWAP_SIZE}"
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap de ${SWAP_SIZE} criado e persistido no fstab"
}

# ─────────────────────────────────────────────
setup_security() {
    log "Configurando segurança básica..."

    # Atualizações de segurança automáticas
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "Atualizações automáticas de segurança ativadas"

    # fail2ban — proteção contra brute-force SSH
    systemctl enable fail2ban && systemctl start fail2ban
    ok "fail2ban ativo"
}

# ─────────────────────────────────────────────
main() {
    echo ""
    echo "================================================="
    echo "  Setup do Servidor Ubuntu — $(date)"
    echo "  Log em: $LOG_FILE"
    echo "================================================="
    echo ""

    setup_packages
    setup_user
    setup_ssh_key
    setup_git
    setup_timezone
    setup_disk_expand
    setup_docker
    setup_swap
    setup_security

    echo ""
    echo "================================================="
    ok "Setup concluído!"
    echo ""
    echo "  Próximos passos:"
    echo "  - Teste o acesso SSH: ssh ${ADMIN_USER}@<ip>"
    echo "  - Log completo em: $LOG_FILE"
    echo "================================================="
    echo ""
}

main "$@"
