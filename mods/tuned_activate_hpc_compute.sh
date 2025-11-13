#!/bin/bash
# Script para activar el perfil 'hpc-compute' de Tuned.
# Requiere permisos de root (sudo).

set -euo pipefail

HPC_PROFILE="hpc-compute"

echo "Aplicando perfil Tuned: $HPC_PROFILE"

# 1. Verificar el perfil activo actual para fines de documentación
CURRENT_PROFILE=$(tuned-adm active | awk '{print $NF}')
echo "Perfil original antes del cambio: $CURRENT_PROFILE"

# 2. Aplicar el perfil de alto rendimiento
sudo tuned-adm profile "$HPC_PROFILE"

echo "El perfil '$HPC_PROFILE' está ahora activo."
echo "Verificando el estado: tuned-adm active"
sudo tuned-adm active
echo ""
sudo tuned-adm verify