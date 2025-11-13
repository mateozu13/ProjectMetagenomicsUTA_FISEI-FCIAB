#!/bin/bash
# Script para configurar y gestionar el montaje en RAM (tmpfs) para archivos temporales de QIIME 2.
# Este montaje acelera las operaciones intensivas de I/O.
# Requiere permisos de root (sudo).

set -euo pipefail

TMPFS_MOUNT_POINT="/mnt/qiime2_tmp"
TMPFS_SIZE="4G" # Ajustar al 50% de la RAM del servidor

# Función para montar el tmpfs
mount_tmpfs() {
    echo "=========================================================="
    echo " MONTANDO TMPFS (RAM Disk) para Procesos Bioinformaticos"
    echo "=========================================================="
    
    # Crear el punto de montaje si no existe
    if [ ! -d "$TMPFS_MOUNT_POINT" ]; then
        echo "Creando directorio de montaje: $TMPFS_MOUNT_POINT"
        sudo mkdir -p "$TMPFS_MOUNT_POINT"
    fi

    # Montar tmpfs con permisos 777 (acceso total para todos los usuarios)
    # y tamaño limitado para proteger la RAM del sistema.
    echo "Montando tmpfs de $TMPFS_SIZE con permisos 777..."
    sudo mount -t tmpfs -o size="$TMPFS_SIZE",nr_inodes=1m,mode=777 tmpfs "$TMPFS_MOUNT_POINT"
    
    echo "Verificación del montaje:"
    df -h | grep "$TMPFS_MOUNT_POINT"
    
    echo ""
    echo "[INFO] Montaje TMPFS completado. Espacio de $TMPFS_SIZE asignado en RAM."
    echo ""
    echo "====================================================="
    echo " INSTRUCCIONES PARA USUARIOS (GRUPO RESEARCH)"
    echo "====================================================="
    echo "Cada usuario debe ejecutar esta línea en sus scripts de QIIME 2 (después de 'conda activate'):"
    echo "export TMPDIR=\"$TMPFS_MOUNT_POINT\""
    echo ""
    echo "Esto redirige los archivos temporales de DADA2, clasificación, etc., a la RAM."
}

# Función para desmontar el tmpfs
unmount_tmpfs() {
    echo "======================="
    echo " DESMONTANDO TMPFS"
    echo "======================="
    
    if mountpoint -q "$TMPFS_MOUNT_POINT"; then
        echo "Desmontando $TMPFS_MOUNT_POINT..."
        sudo umount "$TMPFS_MOUNT_POINT"
        echo "[INFO] Desmontaje completado."
    else
        echo "Advertencia: $TMPFS_MOUNT_POINT no está montado."
    fi
}

# Lógica principal del script
if [ "$#" -eq 0 ]; then
    echo "Uso:"
    echo "  sudo bash $0 mount        # Montar el tmpfs"
    echo "  sudo bash $0 umount      # Desmontar el tmpfs"
elif [ "$1" == "mount" ]; then
    mount_tmpfs
elif [ "$1" == "umount" ]; then
    unmount_tmpfs
else
    echo "Argumento no válido. Use 'mount' o 'umount'."
    exit 1
fi