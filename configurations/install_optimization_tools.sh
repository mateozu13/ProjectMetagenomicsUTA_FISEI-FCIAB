#!/usr/bin/env bash

set -euo pipefail

echo "======================================================================"
echo "  INSTALACIÓN DE HERRAMIENTAS DE OPTIMIZACIÓN - ROCKY LINUX 8.10"
echo "  GNU Parallel, pigz, y herramientas de monitoreo"
echo "======================================================================"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Este script debe ejecutarse como root (sudo)"
   exit 1
fi

echo "[1/5] Actualizando repositorios..."
dnf update -y
echo "    ✓ Repositorios actualizados"
echo ""

echo "[2/5] Habilitando EPEL (Extra Packages for Enterprise Linux)..."
dnf install -y epel-release
dnf config-manager --set-enabled powertools 2>/dev/null || \
dnf config-manager --set-enabled PowerTools 2>/dev/null || \
dnf config-manager --set-enabled crb 2>/dev/null || true
echo "    ✓ EPEL habilitado"
echo ""

echo "[3/5] Instalando GNU Parallel..."
if command -v parallel &> /dev/null; then
    echo "    ⚠ GNU Parallel ya está instalado"
    parallel --version | head -1
else
    dnf install -y parallel
    echo "    ✓ GNU Parallel instalado"
    parallel --version | head -1
fi
echo ""

echo "[4/5] Instalando pigz (compresión paralela)..."
if command -v pigz &> /dev/null; then
    echo "    ⚠ pigz ya está instalado"
    pigz --version 2>&1 | head -1
else
    dnf install -y pigz
    echo "    ✓ pigz instalado"
    pigz --version 2>&1 | head -1
fi
echo ""

echo "[5/5] Instalando herramientas de monitoreo..."

TOOLS_TO_INSTALL=()

if ! command -v pidstat &> /dev/null; then
    TOOLS_TO_INSTALL+=("sysstat")
fi

if ! command -v iostat &> /dev/null; then
    TOOLS_TO_INSTALL+=("sysstat")
fi

if ! command -v htop &> /dev/null; then
    TOOLS_TO_INSTALL+=("htop")
fi

if ! command -v bc &> /dev/null; then
    TOOLS_TO_INSTALL+=("bc")
fi

if [[ ${#TOOLS_TO_INSTALL[@]} -gt 0 ]]; then
    UNIQUE_TOOLS=($(printf "%s\n" "${TOOLS_TO_INSTALL[@]}" | sort -u))
    dnf install -y "${UNIQUE_TOOLS[@]}"
    echo "    ✓ Herramientas de monitoreo instaladas"
else
    echo "    ⚠ Todas las herramientas ya están instaladas"
fi
echo ""

echo "======================================================================"
echo "  CONFIGURACIÓN DE GNU PARALLEL"
echo "======================================================================"
echo ""

PARALLEL_DIR="/etc/parallel"
mkdir -p "$PARALLEL_DIR"

if [[ ! -f "$PARALLEL_DIR/will-cite" ]]; then
    echo "Creando archivo will-cite para suprimir advertencias..."
    touch "$PARALLEL_DIR/will-cite"
    echo "    ✓ Archivo will-cite creado"
else
    echo "    ⚠ Archivo will-cite ya existe"
fi
echo ""

echo "======================================================================"
echo "  CONFIGURACIÓN DE ALIAS GLOBALES"
echo "======================================================================"
echo ""

BASHRC_ADDITIONS="/etc/profile.d/bioinformatics_optimizations.sh"

cat > "$BASHRC_ADDITIONS" << 'EOF'
alias gzip='pigz'
alias gunzip='pigz -d'
alias zcat='pigz -dc'

export GZIP="-p $(nproc)"

parallel_cite() {
    parallel --will-cite "$@"
}

export -f parallel_cite 2>/dev/null || true
EOF

chmod +x "$BASHRC_ADDITIONS"
echo "    ✓ Alias globales configurados en: $BASHRC_ADDITIONS"
echo ""

echo "======================================================================"
echo "  VERIFICACIÓN DE INSTALACIÓN"
echo "======================================================================"
echo ""

EXIT_CODE=0

echo "Verificando GNU Parallel..."
if command -v parallel &> /dev/null; then
    VERSION=$(parallel --version 2>&1 | head -1)
    echo "    ✓ $VERSION"
else
    echo "    ✗ GNU Parallel NO instalado"
    EXIT_CODE=1
fi

echo ""
echo "Verificando pigz..."
if command -v pigz &> /dev/null; then
    VERSION=$(pigz --version 2>&1 | head -1)
    echo "    ✓ $VERSION"
else
    echo "    ✗ pigz NO instalado"
    EXIT_CODE=1
fi

echo ""
echo "Verificando herramientas de monitoreo..."

if command -v pidstat &> /dev/null; then
    echo "    ✓ pidstat disponible"
else
    echo "    ✗ pidstat NO disponible"
    EXIT_CODE=1
fi

if command -v iostat &> /dev/null; then
    echo "    ✓ iostat disponible"
else
    echo "    ✗ iostat NO disponible"
    EXIT_CODE=1
fi

if command -v bc &> /dev/null; then
    echo "    ✓ bc disponible"
else
    echo "    ✗ bc NO disponible"
    EXIT_CODE=1
fi

if command -v htop &> /dev/null; then
    echo "    ✓ htop disponible"
else
    echo "    ⚠ htop NO disponible (opcional)"
fi

echo ""

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "======================================================================"
    echo "  ✓ INSTALACIÓN COMPLETADA EXITOSAMENTE"
    echo "======================================================================"
    echo ""
    echo "HERRAMIENTAS INSTALADAS:"
    echo "------------------------"
    echo "✓ GNU Parallel - Ejecución paralela de comandos"
    echo "✓ pigz - Compresión/descompresión paralela"
    echo "✓ pidstat - Monitoreo de procesos"
    echo "✓ iostat - Monitoreo de I/O"
    echo "✓ bc - Calculadora para scripts"
    echo "✓ htop - Monitor interactivo del sistema"
    echo ""
    echo "CONFIGURACIONES APLICADAS:"
    echo "--------------------------"
    echo "✓ Alias gzip → pigz (compresión paralela automática)"
    echo "✓ Archivo will-cite creado (sin advertencias de citación)"
    echo "✓ Variables de entorno configuradas"
    echo ""
    echo "PRÓXIMOS PASOS:"
    echo "---------------"
    echo "1. Cerrar y reabrir la terminal (o ejecutar: source /etc/profile)"
    echo "2. Verificar con: parallel --version"
    echo "3. Ejecutar pipeline optimizado: bash pipeline_optimized_parallel_stats.sh"
    echo ""
    echo "EJEMPLOS DE USO:"
    echo "----------------"
    echo "# Comprimir archivos en paralelo:"
    echo "  pigz -p 12 archivo.fq"
    echo ""
    echo "# Ejecutar comandos en paralelo:"
    echo "  ls *.fq | parallel 'echo Procesando {}'"
    echo ""
    echo "# Comprimir múltiples archivos:"
    echo "  find . -name '*.fq' | parallel pigz"
    echo ""
    echo "======================================================================"
else
    echo "======================================================================"
    echo "  ✗ INSTALACIÓN INCOMPLETA"
    echo "======================================================================"
    echo ""
    echo "Algunas herramientas no se instalaron correctamente."
    echo "Revise los mensajes de error anteriores."
    echo ""
    echo "Para intentar nuevamente:"
    echo "  sudo bash install_optimization_tools.sh"
    echo ""
    exit 1
fi