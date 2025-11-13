#!/usr/bin/env bash
# Script para configurar una Systemd Slice (Cgroup) dedicada a análisis bioinformáticos
# Objetivo: Priorizar CPU y I/O para mejorar la eficiencia de QIIME 2.

set -euo pipefail

# 1. Definir el nombre del Slice (Cgroup) y el archivo de configuración
SLICE_NAME="bioinfo.slice"
SLICE_FILE="/etc/systemd/system/$SLICE_NAME"

echo "================================================="
echo " PASO 1: Creando el archivo de definición del Slice"
echo "================================================="

# Crear o sobrescribir el archivo de definición del Slice
echo "[Unit]" | sudo tee "$SLICE_FILE" > /dev/null
echo "Description=Slice para Análisis Bioinformático de Alto Rendimiento" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "[Slice]" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "# Prioridad de CPU: Valor de 4096 (por defecto 1024)" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "CPUWeight=4096" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "# Prioridad de I/O: Valor de 4000 (por defecto 1000)" | sudo tee -a "$SLICE_FILE" > /dev/null
echo "IOWeight=4000" | sudo tee -a "$SLICE_FILE" > /dev/null

echo "Archivo $SLICE_FILE creado con éxito."

echo "====================================================="
echo " PASO 2: Recargando y Activando el Slice"
echo "====================================================="

# Recargar la configuración de systemd
echo "Ejecutando: sudo systemctl daemon-reload"
sudo systemctl daemon-reload

# Iniciar el Slice. Esto lo hace persistente y disponible
echo "Ejecutando: sudo systemctl enable --now $SLICE_NAME"
sudo systemctl enable --now "$SLICE_NAME"

# Verificar el estado
echo ""
echo "Verificación del estado del Slice:"
sudo systemctl status "$SLICE_NAME" | grep "Active"

echo "================================================="
echo " Ejemplo de Uso"
echo "================================================="

echo "El Slice $SLICE_NAME está listo para usarse."
echo ""
echo "Ejemplo de uso para ejecutar scripts de QIIME 2 / DADA2 con alta prioridad:"
echo ""
echo "systemd-run \\"
echo "  --slice=$SLICE_NAME \\"
echo "  --unit=qiime2_denoising \\"
echo "  --nice=-10 \\"
echo "  /ruta/hacia/qiime2_script.sh"
echo ""
```eof