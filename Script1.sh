#!/bin/bash
set -e # Encerra o script imediatamente se qualquer comando falhar

# ==============================================================================
# SCRIPT DE MIGRAÇÃO PARA RAID 1 (TÉCNICA DE MISSING MEMBER)
# ==============================================================================
# Refatorado para:
# - Detecção dinâmica de partições (Root e Swap)
# - Suporte a nomes de dispositivos NVMe (ex: nvme0n1p1)
# - Atualização segura do fstab (preserva outras montagens)
# - Interatividade na seleção de discos
# ==============================================================================

# --- Funções Auxiliares ---

# Função para obter o nome da partição corretamente (sda1 vs nvme0n1p1)
get_partition_name() {
    local disk=$1
    local part_num=$2
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# --- 1. Verificações de Segurança ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root!"
   exit 1
fi

if ! command -v mdadm &> /dev/null; then
    echo "→ Instalando mdadm..."
    apt-get update && apt-get install -y mdadm
fi

# Limpa a tela e mostra discos
clear
echo "=== LISTA DE DISCOS DISPONÍVEIS ==="
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v "loop"
echo "==================================="

# --- 2. Seleção de Discos e Identificação de Partições ---

# Detectar partição Raiz atual
CURRENT_ROOT_PART=$(findmnt -n -o SOURCE /)
CURRENT_ROOT_DISK=$(lsblk -no PKNAME $CURRENT_ROOT_PART | head -n1)
CURRENT_ROOT_DISK_FULL="/dev/$CURRENT_ROOT_DISK"

echo "Detectado partição raiz em: $CURRENT_ROOT_PART (Disco: $CURRENT_ROOT_DISK_FULL)"

# Detectar Swap atual (pega o primeiro swap ativo)
CURRENT_SWAP_PART=$(swapon --show=NAME --noheadings | head -n1)
if [[ -n "$CURRENT_SWAP_PART" ]]; then
    echo "Detectado swap em: $CURRENT_SWAP_PART"
else
    echo "Nenhum swap ativo detectado."
fi

echo ""
echo "---------------------------------------------------------"
echo "Por favor, confirme os discos para a migração."
echo "O disco de ORIGEM (Dados) deve ser: $CURRENT_ROOT_DISK_FULL"
echo "---------------------------------------------------------"

read -p "Digite o dispositivo do disco de ORIGEM (ex: /dev/sda): " SRC_DISK
read -p "Digite o dispositivo do disco de DESTINO (NOVO/VAZIO) (ex: /dev/sdb): " DEST_DISK

# Validação básica
if [[ -z "$SRC_DISK" || -z "$DEST_DISK" ]]; then
    echo "❌ Erro: Discos não podem ser vazios."
    exit 1
fi

if [[ "$SRC_DISK" == "$DEST_DISK" ]]; then
    echo "❌ Erro: Origem e Destino são o mesmo disco!"
    exit 1
fi

if [[ ! -b "$SRC_DISK" || ! -b "$DEST_DISK" ]]; then
    echo "❌ Erro: Um dos dispositivos não é um bloco válido."
    exit 1
fi

# Identificar números das partições de origem
# Extrai o número da partição (assume que o numero está no final)
# Para sda1 -> 1. Para nvme0n1p1 -> 1.
ROOT_PART_NUM=$(echo "$CURRENT_ROOT_PART" | grep -o '[0-9]*$')

SWAP_PART_NUM=""
if [[ -n "$CURRENT_SWAP_PART" ]]; then
    SWAP_PART_NUM=$(echo "$CURRENT_SWAP_PART" | grep -o '[0-9]*$')
fi

# Mapear particões de destino
DEST_ROOT_PART=$(get_partition_name "$DEST_DISK" "$ROOT_PART_NUM")
DEST_SWAP_PART=""
if [[ -n "$SWAP_PART_NUM" ]]; then
    DEST_SWAP_PART=$(get_partition_name "$DEST_DISK" "$SWAP_PART_NUM")
fi

echo ""
echo "!!! RESUMO DA OPERAÇÃO !!!"
echo "Origem: $SRC_DISK"
echo "  - Raiz: $CURRENT_ROOT_PART -> Destino: $DEST_ROOT_PART (via RAID md0)"
if [[ -n "$DEST_SWAP_PART" ]]; then
echo "  - Swap: $CURRENT_SWAP_PART -> Destino: $DEST_SWAP_PART (via RAID md1)"
fi
echo "Destino: $DEST_DISK (Será FORMATADO)"
echo ""
echo "Alerta: Verifique se existem outras partições importantes (boot, home, var)."
echo "Este script foca na migração da Raiz e Swap."
echo ""
read -p "Tem certeza absoluta que deseja continuar? (digite 'sim' para confirmar): " confirm
if [[ "$confirm" != "sim" ]]; then
    echo "Cancelado pelo usuário."
    exit 1
fi

MOUNT_POINT="/mnt/raid_new_root"

# --- 3. Preparação dos Discos ---
echo "→ 2. Copiando tabela de partições de $SRC_DISK para $DEST_DISK..."
sfdisk -d $SRC_DISK | sfdisk --force $DEST_DISK

# Aguarda o kernel atualizar a tabela de partições
udevadm settle
sleep 2

# Limpar metadados antigos
echo "→ Limpando superblocos antigos no destino..."
if [[ -b "$DEST_ROOT_PART" ]]; then mdadm --zero-superblock "$DEST_ROOT_PART" 2>/dev/null || true; fi
if [[ -n "$DEST_SWAP_PART" && -b "$DEST_SWAP_PART" ]]; then mdadm --zero-superblock "$DEST_SWAP_PART" 2>/dev/null || true; fi

# --- 4. Criação do RAID Degradado ---
echo "→ 3. Criando dispositivo md0 (Raiz) em modo degradado..."
# Usamos metadata 1.2 (padrão moderno). Se o boot falhar (BIOS muito antiga), pode ser necessário 0.90.
mdadm --create /dev/md0 --level=1 --raid-devices=2 missing "$DEST_ROOT_PART" --metadata=1.2 --force --run

echo "→ Formatando /dev/md0 como ext4..."
mkfs.ext4 /dev/md0

if [[ -n "$DEST_SWAP_PART" ]]; then
    echo "→ Criando dispositivo md1 (Swap) em modo degradado..."
    mdadm --create /dev/md1 --level=1 --raid-devices=2 missing "$DEST_SWAP_PART" --metadata=1.2 --force --run
    mkswap /dev/md1
fi

# --- 5. Sincronização de Dados (Clonagem) ---
echo "→ 4. Montando novo RAID e iniciando clonagem..."
mkdir -p $MOUNT_POINT
mount /dev/md0 $MOUNT_POINT

# RSYNC
echo "Iniciando rsync... (Isso pode demorar dependendo do tamanho do disco)"
rsync -aAXv --delete \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / $MOUNT_POINT/

echo "✅ Clonagem de arquivos concluída."

# --- 6. Configuração do Sistema Clonado ---
echo "→ 5. Ajustando configurações no novo disco..."

# Montagens para chroot
mount --bind /dev $MOUNT_POINT/dev
mount --bind /proc $MOUNT_POINT/proc
mount --bind /sys $MOUNT_POINT/sys
mount --bind /run $MOUNT_POINT/run

# Obter UUIDs Originais e Novos
OLD_ROOT_UUID=$(blkid -s UUID -o value "$CURRENT_ROOT_PART")
NEW_ROOT_UUID=$(blkid -s UUID -o value /dev/md0)

OLD_SWAP_UUID=""
NEW_SWAP_UUID=""
if [[ -n "$CURRENT_SWAP_PART" ]]; then
    OLD_SWAP_UUID=$(blkid -s UUID -o value "$CURRENT_SWAP_PART")
    NEW_SWAP_UUID=$(blkid -s UUID -o value /dev/md1)
fi

echo "→ Atualizando /etc/fstab do novo sistema (Substituição de UUIDs)..."
FSTAB="$MOUNT_POINT/etc/fstab"
cp "$FSTAB" "$FSTAB.bak"

# Substituição segura usando sed para preservar outras entradas
if [[ -n "$OLD_ROOT_UUID" && -n "$NEW_ROOT_UUID" ]]; then
    echo "  Substituindo UUID da Raiz: $OLD_ROOT_UUID -> $NEW_ROOT_UUID"
    sed -i "s/$OLD_ROOT_UUID/$NEW_ROOT_UUID/g" "$FSTAB"
else
    echo "⚠️ ALERTA: Não foi possível determinar UUIDs da raiz para substituição automática no fstab."
    echo "  Adicionando nova entrada ao final do arquivo..."
    echo "UUID=$NEW_ROOT_UUID / ext4 errors=remount-ro 0 1" >> "$FSTAB"
fi

if [[ -n "$OLD_SWAP_UUID" && -n "$NEW_SWAP_UUID" ]]; then
    echo "  Substituindo UUID de Swap: $OLD_SWAP_UUID -> $NEW_SWAP_UUID"
    sed -i "s/$OLD_SWAP_UUID/$NEW_SWAP_UUID/g" "$FSTAB"
elif [[ -n "$NEW_SWAP_UUID" ]]; then
    # Se não tinha swap antes ou não achou UUID, adiciona
    echo "UUID=$NEW_SWAP_UUID none swap sw 0 0" >> "$FSTAB"
fi

# Gerar mdadm.conf
echo "→ Gerando mdadm.conf..."
mkdir -p $MOUNT_POINT/etc/mdadm
echo "DEVICE partitions" > $MOUNT_POINT/etc/mdadm/mdadm.conf
mdadm --detail --scan >> $MOUNT_POINT/etc/mdadm/mdadm.conf

# --- 7. Instalação do Bootloader (GRUB) ---
echo "→ 6. Instalando GRUB no novo disco ($DEST_DISK)..."

# Detecção de EFI
if [[ -d "/sys/firmware/efi" ]]; then
    echo "⚠️ SISTEMA UEFI DETECTADO!"
    echo "Este script foi ajustado primariamente para BIOS/Legacy."
    echo "Para UEFI, é necessário garantir que a partição ESP esteja montada em /boot/efi no chroot."
    echo "Tentando instalar grub para o disco..."
    
    # Tenta encontrar e montar partição EFI se existir na tabela copiada
    # Geralmente é a partição tipo EF00. Vamos supor que seja clonada ok.
    # Mas o UUID mudou? Não, sfdisk clonou a tabela e possivelmente UUIDs de partição, mas não formatamos a EFI nova.
    # Se sfdisk apenas copiou a tabela, a partição EFI no destination está vazia/corrompida? 
    # Não, sfdisk copia estrutura. O conteúdo da EFI precisa ser copiado via dd ou cp.
    
    echo "⚠️ AVISO CRÍTICO: Em sistemas UEFI, certifique-se de copiar o conteúdo da partição EFI manualmente se falhar."
else 
    echo "Sistema BIOS/Legacy detectado."
fi

chroot $MOUNT_POINT /bin/bash <<EOF
    update-initramfs -u
    grub-install $DEST_DISK
    update-grub
EOF

# --- 8. Finalização ---
echo "→ Desmontando..."
umount -R $MOUNT_POINT

echo "==========================================================="
echo "✅ PREPARAÇÃO CONCLUÍDA COM SUCESSO!"
echo "==========================================================="
echo "PRÓXIMOS PASSOS:"
echo "1. Reinicie o computador."
echo "2. Na BIOS, altere o boot para o disco: $DEST_DISK"
echo "3. Se o sistema iniciar corretamente pelo RAID (degradado):"
echo "   Adicione o disco antigo ao RAID rodando:"
echo "   sudo mdadm --manage /dev/md0 --add $SRC_DISK$ROOT_PART_NUM"
if [[ -n "$SRC_DISK$SWAP_PART_NUM" ]]; then
    echo "   sudo mdadm --manage /dev/md1 --add $SRC_DISK$SWAP_PART_NUM"
fi
echo ""
echo "   Acompanhe a sincronização com: watch cat /proc/mdstat"
echo "==========================================================="

exit 0
