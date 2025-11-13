#!/bin/bash
# Script para configurar límites de recursos de usuario para el grupo de investigación.
# Aumenta 'nofile' (archivos abiertos) y 'nproc' (procesos) para prevenir fallos en análisis masivos.
# Requiere permisos de root (sudo).

set -euo pipefail

LIMITS_FILE="/etc/security/limits.conf"
TARGET_GROUP="research"
NOFILE_LIMIT="65536"
NPROC_LIMIT="4096"

echo "Configurando límites (ulimit) para el grupo @$TARGET_GROUP en $LIMITS_FILE"

# Función para añadir o reemplazar un límite
configure_limit() {
    local type=$1
    local soft_limit=$2
    local hard_limit=$3
    local description=$4

    # Patrón de búsqueda para líneas existentes del grupo
    SEARCH_PATTERN="^@$TARGET_GROUP.*$type"
    
    # Líneas a insertar
    SOFT_LINE="@$TARGET_GROUP\tsoft\t$type\t$soft_limit"
    HARD_LINE="@$TARGET_GROUP\thard\t$type\t$hard_limit"

    # Si la línea ya existe, sed la reemplazará
    if grep -q "$SEARCH_PATTERN" "$LIMITS_FILE"; then
        echo "Límite $type existente. Actualizando..."
        # Reemplazar líneas soft y hard existentes
        sudo sed -i "/^@$TARGET_GROUP.*soft.*$type/c\\$SOFT_LINE" "$LIMITS_FILE"
        sudo sed -i "/^@$TARGET_GROUP.*hard.*$type/c\\$HARD_LINE" "$LIMITS_FILE"
    else
        # Si no existe, añadir al final
        echo "Añadiendo límite $type."
        echo "# $description para el grupo $TARGET_GROUP" | sudo tee -a "$LIMITS_FILE" > /dev/null
        echo -e "$SOFT_LINE" | sudo tee -a "$LIMITS_FILE" > /dev/null
        echo -e "$HARD_LINE" | sudo tee -a "$LIMITS_FILE" > /dev/null
    fi
}

# 1. Configurar límites de archivos abiertos (nofile)
configure_limit "nofile" "$NOFILE_LIMIT" "$NOFILE_LIMIT" "Limite de archivos abiertos (nofile)"

# 2. Configurar límites de procesos (nproc)
configure_limit "nproc" "$NPROC_LIMIT" "$NPROC_LIMIT" "Limite de procesos (nproc)"

echo "======================================================="
echo "Verifique las nuevas líneas en $LIMITS_FILE"
echo "======================================================="
sudo grep "@$TARGET_GROUP" "$LIMITS_FILE"

echo ""
echo "[INFO] Para revertir estos cambios y eliminarlos de $LIMITS_FILE, ejecute el siguiente comando:"
echo "sudo sed -i '/@$TARGET_GROUP/d' /etc/security/limits.conf"

echo "!!! ACCIÓN REQUERIDA !!!"
echo "Para que estos cambios surtan efecto en las sesiones existentes, los usuarios deben CERRAR SESIÓN y VOLVER A INICIAR SESIÓN."
echo ""
echo "Una vez iniciada la sesión, verifique los límites con el comando:"
echo "ulimit -n"