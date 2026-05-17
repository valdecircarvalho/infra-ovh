#!/usr/bin/env bash
# Backup de containers para o repo privado infra-ovh-backup
# Config em /etc/infra-backup.conf — nunca commitar esse arquivo
# Agendar via cron: 0 3 * * * /opt/containers/scripts/backup.sh
set -euo pipefail

CONFIG_FILE="/etc/infra-backup.conf"
BACKUP_REPO="https://github.com/valdecircarvalho/infra-ovh-backup.git"
BACKUP_WORK_DIR="/tmp/infra-ovh-backup"
CONTAINERS_DIR="/opt/containers"
LOG_FILE="/var/log/infra-backup.log"

exec >> "$LOG_FILE" 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "Arquivo de config não encontrado: $CONFIG_FILE
Crie o arquivo com:
  echo 'GITHUB_TOKEN=seu_token_aqui' | sudo tee $CONFIG_FILE
  sudo chmod 600 $CONFIG_FILE"

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN não definido em $CONFIG_FILE"

REPO_URL="https://${GITHUB_TOKEN}@github.com/valdecircarvalho/infra-ovh-backup.git"

# ─────────────────────────────────────────────
backup_npm() {
    local SERVICE="nginx-proxy-manager"
    local SRC="${CONTAINERS_DIR}/${SERVICE}"
    local DST="${BACKUP_WORK_DIR}/${SERVICE}"

    [[ -d "$SRC" ]] || { warn "Diretório $SRC não encontrado — pulando NPM"; return 0; }

    log "Fazendo backup do $SERVICE..."
    mkdir -p "$DST"

    # .env
    [[ -f "${SRC}/.env" ]] && cp "${SRC}/.env" "${DST}/.env" && ok ".env copiado"

    # pg_dump
    if docker ps --format '{{.Names}}' | grep -q "^nginx-proxy-manager-db$"; then
        docker exec nginx-proxy-manager-db \
            pg_dump -U npm npm > "${DST}/npm-db.sql"
        ok "pg_dump concluído"
    else
        warn "Container nginx-proxy-manager-db não está rodando — dump ignorado"
    fi

    # certificados letsencrypt
    if [[ -d "${SRC}/letsencrypt" ]]; then
        tar -czf "${DST}/letsencrypt.tar.gz" -C "$SRC" letsencrypt
        ok "letsencrypt arquivado"
    fi

    ok "$SERVICE backup concluído"
}

# ─────────────────────────────────────────────
main() {
    log "====== Início do backup — $(date) ======"

    # Clona ou atualiza o repo privado
    if [[ -d "${BACKUP_WORK_DIR}/.git" ]]; then
        git -C "$BACKUP_WORK_DIR" remote set-url origin "$REPO_URL"
        git -C "$BACKUP_WORK_DIR" pull --rebase
    else
        rm -rf "$BACKUP_WORK_DIR"
        git clone "$REPO_URL" "$BACKUP_WORK_DIR"
    fi

    backup_npm
    # backup_outro_servico  ← adicione aqui conforme crescer

    # Commit e push
    git -C "$BACKUP_WORK_DIR" config user.name  "Valdecir Carvalho"
    git -C "$BACKUP_WORK_DIR" config user.email "valdecir.carvalho@outlook.com"
    git -C "$BACKUP_WORK_DIR" add -A

    if git -C "$BACKUP_WORK_DIR" diff --cached --quiet; then
        ok "Nenhuma alteração desde o último backup"
    else
        git -C "$BACKUP_WORK_DIR" commit -m "backup: $(date '+%Y-%m-%d %H:%M:%S')"
        git -C "$BACKUP_WORK_DIR" push
        ok "Backup enviado para o repo privado"
    fi

    log "====== Backup concluído ======"
}

main "$@"
