#!/bin/bash
set -e # Encerra o script imediatamente se qualquer comando falhar

# ==============================================================================
# SCRIPT DE MIGRAÇÃO PARA RAID 1 (TÉCNICA DE MISSING MEMBER)
# ==============================================================================
# Cenário:
# - Disco Origem (Dados atuais): /dev/sda
# - Disco Destino (Novo/Vazio): /dev/sdb
#
# O que este script faz:
# 1. Copia a tabela de partições de sda para sdb.
# 2. Cria um RAID "degradado" em sdb (com o outro disco marcado como 'missing').
# 3. Formata e monta o novo RAID.
# 4. Clona o sistema rodando para o RAID usando rsync.
# 5. Prepara o bootloader (GRUB) e fstab no novo RAID.
# ==============================================================================

SRC_DISK="/dev/sda"
DEST_DISK="/dev/sdb"
MOUNT_POINT="/mnt/raid_new_root"

# --- 1. Verificações de Segurança ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root!"
   exit 1
fi

if ! command -v mdadm &> /dev/null; then
    echo "→ Instalando mdadm..."
    apt-get update && apt-get install -y mdadm
fi

echo "!!! ATENÇÃO !!!"
echo "Você está prestes a clonar $SRC_DISK para $DEST_DISK e criar um RAID 1."
echo "O disco $DEST_DISK será TOTALMENTE APAGADO."
echo "Certifique-se de que $SRC_DISK é o disco do SO e $DEST_DISK é o novo."
echo ""
read -p "Tem certeza absoluta que deseja continuar? (digite 'sim'): " confirm
if [[ "$confirm" != "sim" ]]; then
    echo "Cancelado."
    exit 1
fi

# --- 2. Preparação dos Discos ---
echo "→ 2. Copiando tabela de partições de $SRC_DISK para $DEST_DISK..."
sfdisk -d $SRC_DISK | sfdisk --force $DEST_DISK

# Limpar metadados antigos no disco novo para evitar conflitos
mdadm --zero-superblock ${DEST_DISK}1 2>/dev/null || true
mdadm --zero-superblock ${DEST_DISK}2 2>/dev/null || true

# --- 3. Criação do RAID Degradado ---
# Assumindo layout: Partição 1 = Raiz (/), Partição 2 = Swap
# Criamos o RAID com 'missing' no lugar do sda, pois sda ainda está em uso.

echo "→ 3. Criando dispositivo md0 (Raiz) em modo degradado..."
# Usamos metadata 0.90 ou 1.0 para boot legacy/bios ser mais compatível, 
# mas 1.2 é padrão moderno. Se der erro no boot, pode ser necessário metadata=0.90
mdadm --create /dev/md0 --level=1 --raid-devices=2 missing ${DEST_DISK}1 --metadata=1.2 --force --run

echo "→ Formatando /dev/md0 como ext4..."
mkfs.ext4 /dev/md0

# Configurar SWAP se existir a partição 2
if [[ -b ${SRC_DISK}2 ]]; then
    echo "→ Configurando RAID para Swap..."
    mdadm --create /dev/md1 --level=1 --raid-devices=2 missing ${DEST_DISK}2 --metadata=1.2 --force --run
    mkswap /dev/md1
fi

# --- 4. Sincronização de Dados (Clonagem) ---
echo "→ 4. Montando novo RAID e iniciando clonagem (Isso pode demorar)..."
mkdir -p $MOUNT_POINT
mount /dev/md0 $MOUNT_POINT

# RSYNC: Copia tudo da raiz, exceto pastas virtuais do sistema
rsync -aAXv --delete \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / $MOUNT_POINT/

echo "✅ Clonagem de arquivos concluída."

# --- 5. Configuração do Sistema Clonado ---
echo "→ 5. Ajustando configurações no novo disco..."

# Preparar ambiente CHROOT (necessário para instalar o GRUB no novo disco)
mount --bind /dev $MOUNT_POINT/dev
mount --bind /proc $MOUNT_POINT/proc
mount --bind /sys $MOUNT_POINT/sys
mount --bind /run $MOUNT_POINT/run

# Obter UUIDs
UUID_MD0=$(blkid -s UUID -o value /dev/md0)
if [[ -b /dev/md1 ]]; then
    UUID_MD1=$(blkid -s UUID -o value /dev/md1)
fi

# Atualizar fstab no destino
echo "→ Atualizando /etc/fstab do novo sistema..."
FSTAB="$MOUNT_POINT/etc/fstab"

# Faz backup do fstab original
cp $FSTAB $FSTAB.bak

# Remove linhas antigas e insere as novas (simplificado para Root e Swap)
# Nota: Isso substitui o fstab. Ajuste se tiver outras montagens (home, var).
echo "# /etc/fstab: static file system information." > $FSTAB
echo "UUID=$UUID_MD0 / ext4 errors=remount-ro 0 1" >> $FSTAB
if [[ -n "$UUID_MD1" ]]; then
    echo "UUID=$UUID_MD1 none swap sw 0 0" >> $FSTAB
fi

# Gerar mdadm.conf dentro do novo sistema
echo "→ Gerando mdadm.conf..."
mkdir -p $MOUNT_POINT/etc/mdadm
echo "DEVICE partitions" > $MOUNT_POINT/etc/mdadm/mdadm.conf
mdadm --detail --scan >> $MOUNT_POINT/etc/mdadm/mdadm.conf

# --- 6. Instalação do Bootloader (GRUB) ---
echo "→ 6. Instalando GRUB no novo disco ($DEST_DISK)..."

# Executa comandos DENTRO do novo disco
chroot $MOUNT_POINT /bin/bash <<EOF
    update-initramfs -u
    grub-install $DEST_DISK
    update-grub
EOF

# --- 7. Finalização ---
echo "→ Desmontando..."
umount -R $MOUNT_POINT

echo "==========================================================="
echo "✅ PREPARAÇÃO CONCLUÍDA COM SUCESSO!"
echo "==========================================================="
echo "PRÓXIMOS PASSOS (LEIA COM ATENÇÃO):"
echo "1. Reinicie o computador."
echo "2. Entre na BIOS/UEFI e altere a ordem de boot para iniciar pelo NOVO disco ($DEST_DISK)."
echo "3. Se o sistema iniciar corretamente, você estará rodando no RAID (em modo degradado)."
echo ""
echo "4. PARA FINALIZAR (Adicionar o disco antigo ao RAID):"
echo "   Abra o terminal e execute:"
echo "   sudo mdadm --manage /dev/md0 --add $SRC_DISK'1"
echo "   sudo mdadm --manage /dev/md1 --add $SRC_DISK'2 (se houver swap)"
echo ""
echo "   O RAID começará a sincronizar (rebuild). Monitore com: watch cat /proc/mdstat"
echo "==========================================================="

# Verificação de sucesso
lsblk && fdisk -l
echo "→ Verifique se tudo está correto e funcionando!"
testar 5.4 "Verificação de UUID" \
    "grep -q 'UUID=' /home/matheusp/Projetos_Scripts/Projeto1.sh" \
    "crítico"
testar 5.5 "Configuração de GRUB" \
    "grep -q 'grub-install' /home/matheusp/Projetos_Scripts/Projeto1.sh" \
    "crítico"   
echo "→ Script finalizado."
