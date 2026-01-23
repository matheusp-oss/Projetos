#!/bin/bash
set -e

# ==============================================================================
# SCRIPT DE MIGRAÇÃO PARA RAID 1 (MISSING MEMBER) - V2.0 (UEFI READY)
# ==============================================================================

# --- Funções Auxiliares ---

get_partition_name() {
    local disk=$1
    local part_num=$2
    if [[ "$disk" =~ "nvme" || "$disk" =~ "mmcblk" ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# --- 1. Verificações Iniciais ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root!"
   exit 1
fi

if ! command -v mdadm &> /dev/null; then
    echo "→ Instalando mdadm..."
    apt-get update && apt-get install -y mdadm
fi

clear
echo "=== LISTA DE DISCOS ==="
lsblk -d -o NAME,SIZE,MODEL,TYPE,TRAN | grep -v "loop"
echo "======================="

# --- 2. Seleção e Validação ---

# Detectar Raiz
CURRENT_ROOT_PART=$(findmnt -n -o SOURCE /)
CURRENT_ROOT_DISK=$(lsblk -no PKNAME $CURRENT_ROOT_PART | head -n1)
CURRENT_ROOT_DISK_FULL="/dev/$CURRENT_ROOT_DISK"

# Detectar Swap
CURRENT_SWAP_PART=$(swapon --show=NAME --noheadings | head -n1)

# Detectar EFI/Boot
EFI_PART=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)

echo "--- Configuração Atual ---"
echo "Raiz: $CURRENT_ROOT_PART (Disco: $CURRENT_ROOT_DISK_FULL)"
[[ -n "$CURRENT_SWAP_PART" ]] && echo "Swap: $CURRENT_SWAP_PART" || echo "Swap: Não detectado"
[[ -n "$EFI_PART" ]] && echo "UEFI ESP: $EFI_PART" || echo "Modo: BIOS/Legacy (ou EFI não montado)"
echo "--------------------------"

read -p "Disco de ORIGEM (ex: /dev/sda): " SRC_DISK
read -p "Disco de DESTINO (ex: /dev/sdb): " DEST_DISK

# Validações
if [[ -z "$SRC_DISK" || -z "$DEST_DISK" || "$SRC_DISK" == "$DEST_DISK" ]]; then
    echo "❌ Erro: Discos inválidos ou iguais."
    exit 1
fi

# Verificar tamanhos (Destino deve ser >= Origem)
SIZE_SRC=$(lsblk -b -n -o SIZE $SRC_DISK | head -n1)
SIZE_DEST=$(lsblk -b -n -o SIZE $DEST_DISK | head -n1)

if (( SIZE_DEST < SIZE_SRC )); then
    echo "❌ Erro Crítico: O disco de destino é MENOR que a origem."
    exit 1
fi

# Mapeamento de Partições
ROOT_PART_NUM=$(echo "$CURRENT_ROOT_PART" | grep -o '[0-9]*$')
DEST_ROOT_PART=$(get_partition_name "$DEST_DISK" "$ROOT_PART_NUM")

DEST_SWAP_PART=""
if [[ -n "$CURRENT_SWAP_PART" ]]; then
    SWAP_PART_NUM=$(echo "$CURRENT_SWAP_PART" | grep -o '[0-9]*$')
    DEST_SWAP_PART=$(get_partition_name "$DEST_DISK" "$SWAP_PART_NUM")
fi

DEST_EFI_PART=""
if [[ -n "$EFI_PART" ]]; then
    EFI_PART_NUM=$(echo "$EFI_PART" | grep -o '[0-9]*$')
    DEST_EFI_PART=$(get_partition_name "$DEST_DISK" "$EFI_PART_NUM")
fi

echo ""
echo "!!! ATENÇÃO: O DISCO $DEST_DISK SERÁ FORMATADO !!!"
read -p "Digite 'CONFIRMAR' para continuar: " confirm
if [[ "$confirm" != "CONFIRMAR" ]]; then exit 1; fi

MOUNT_POINT="/mnt/raid_new_root"

# --- 3. Clonagem da Tabela de Partição ---
echo "→ Clonando tabela de partições..."
sfdisk -d $SRC_DISK | sfdisk --force $DEST_DISK
udevadm settle
sleep 3

# Limpeza de metadados
mdadm --zero-superblock "$DEST_ROOT_PART" 2>/dev/null || true
[[ -n "$DEST_SWAP_PART" ]] && mdadm --zero-superblock "$DEST_SWAP_PART" 2>/dev/null || true

# --- 4. Criação do RAID ---
echo "→ Criando MD0 (Raiz)..."
mdadm --create /dev/md0 --level=1 --raid-devices=2 missing "$DEST_ROOT_PART" --metadata=1.2 --force --run
mkfs.ext4 -F /dev/md0

if [[ -n "$DEST_SWAP_PART" ]]; then
    echo "→ Criando MD1 (Swap)..."
    mdadm --create /dev/md1 --level=1 --raid-devices=2 missing "$DEST_SWAP_PART" --metadata=1.2 --force --run
    mkswap /dev/md1
fi

# Tratamento UEFI
if [[ -n "$DEST_EFI_PART" ]]; then
    echo "→ Formatando Partição EFI no destino ($DEST_EFI_PART)..."
    mkfs.vfat -F32 "$DEST_EFI_PART"
fi

# --- 5. Migração de Dados ---
echo "→ Montando e sincronizando dados..."
mkdir -p $MOUNT_POINT
mount /dev/md0 $MOUNT_POINT

# Rsync com -H para hardlinks
echo "Executando rsync..."
rsync -aAXHv --delete \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / $MOUNT_POINT/

# Migração UEFI
if [[ -n "$DEST_EFI_PART" ]]; then
    echo "→ Clonando dados da partição EFI..."
    mkdir -p $MOUNT_POINT/boot/efi
    mount "$DEST_EFI_PART" $MOUNT_POINT/boot/efi
    # Copia o conteúdo da EFI antiga para a nova
    rsync -aAXv /boot/efi/ $MOUNT_POINT/boot/efi/
fi

# --- 6. Pós-Configuração ---
echo "→ Configurando novo sistema..."

# Montagens para chroot
for i in /dev /dev/pts /proc /sys /run; do mount -B $i $MOUNT_POINT$i; done

# Atualização Inteligente do FSTAB
FSTAB="$MOUNT_POINT/etc/fstab"
cp "$FSTAB" "$FSTAB.bak"

NEW_ROOT_UUID=$(blkid -s UUID -o value /dev/md0)
[[ -n "$DEST_SWAP_PART" ]] && NEW_SWAP_UUID=$(blkid -s UUID -o value /dev/md1)

# Comenta entradas antigas para evitar conflito
sed -i '/\s\/\s/s/^/#OLD_ROOT /' "$FSTAB"
sed -i '/\sswap\s/s/^/#OLD_SWAP /' "$FSTAB"

# Insere novas entradas
echo "UUID=$NEW_ROOT_UUID / ext4 errors=remount-ro 0 1" >> "$FSTAB"
if [[ -n "$NEW_SWAP_UUID" ]]; then
    echo "UUID=$NEW_SWAP_UUID none swap sw 0 0" >> "$FSTAB"
fi

# Atualiza mdadm.conf
mkdir -p $MOUNT_POINT/etc/mdadm
echo "DEVICE partitions" > $MOUNT_POINT/etc/mdadm/mdadm.conf
mdadm --detail --scan >> $MOUNT_POINT/etc/mdadm/mdadm.conf

# Bootloader
echo "→ Instalando GRUB..."
chroot $MOUNT_POINT /bin/bash <<EOF
    update-initramfs -u
    grub-install $DEST_DISK --recheck
    update-grub
EOF

# Desmontagem
umount -R $MOUNT_POINT
echo "✅ SUCESSO! Reinicie, selecione o disco $DEST_DISK na BIOS."
echo "Após bootar, adicione o disco antigo ao RAID:"
echo "sudo mdadm --manage /dev/md0 --add $SRC_DISK$ROOT_PART_NUM"
