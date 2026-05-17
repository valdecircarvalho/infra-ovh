# infra-ovh

Repositório de scripts e configurações de infraestrutura.

## Setup de servidor Ubuntu

Executa toda a configuração inicial em um único comando:

```bash
curl -fsSL https://raw.githubusercontent.com/valdecircarvalho/infra-ovh/main/setup.sh | sudo bash
```

### O que o script faz

| Passo | Descrição |
|---|---|
| Pacotes | git, curl, wget, net-tools, htop, ncdu, iotop, tmux, jq, tree e outros |
| Usuário | Cria `valdecir` com sudo sem senha |
| SSH | Instala a chave pública de `keys/authorized_keys` para `root` e `valdecir` |
| Git | Configura `user.name`, `user.email`, editor (nano) e branch padrão (main) |
| Timezone | America/Sao_Paulo |
| Disco | Expande LVM automaticamente se o disco foi ampliado no ESXi (growpart + pvresize + lvextend + resize2fs) |
| Docker | Instala Docker CE + Compose plugin; adiciona `valdecir` e `administrator` ao grupo docker |
| Swap | Cria swapfile proporcional ao RAM (≤2 GB → RAM×1 / 2–8 GB → 2 GB / 8–32 GB → 4 GB / >32 GB → 8 GB) |
| Segurança | fail2ban + unattended-upgrades (patches de segurança automáticos) |

Log da execução salvo em `/var/log/server-setup-YYYYMMDD-HHMMSS.log`.

### Estrutura

```
infra-ovh/
├── setup.sh              # script de setup
└── keys/
    └── authorized_keys   # chave pública SSH
```

### Pós-setup

```bash
# Testar acesso SSH
ssh valdecir@<ip>

# Verificar Docker
docker run hello-world

# Verificar espaço em disco
df -h /
```
