#!/bin/bash
# Script para restaurar el perfil 'virtual-guest' de Tuned.
# Requiere permisos de root (sudo).

set -euo pipefail

RESTORE_PROFILE="virtual-guest"

echo "Restaurando perfil Tuned a: $RESTORE_PROFILE"

# 1. Aplicar el perfil original
sudo tuned-adm profile "$RESTORE_PROFILE"

echo "El perfil '$RESTORE_PROFILE' ha sido restaurado."
echo "Verificando el estado: tuned-adm active"
sudo tuned-adm active
echo ""
sudo tuned-adm verify