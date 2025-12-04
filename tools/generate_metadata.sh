#!/usr/bin/env bash
################################################################################
# Generador automático de metadata.tsv para proyectos de microbioma
# 
# Uso: bash generate_metadata.sh <nombre_proyecto>
# Ejemplo: bash generate_metadata.sh Proyecto1_20251103
################################################################################

set -euo pipefail

# Verificar argumento
if [[ $# -ne 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto>"
  echo "Ejemplo: bash $0 Proyecto1_20241113"
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"
RAW_DIR="$PROJECT_DIR/raw_sequences"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

echo ""
echo "=========================================="
echo "Generador de Metadata QIIME2"
echo "=========================================="
echo "Proyecto: $PROJECT_NAME"
echo ""

# Verificar que existe el directorio del proyecto
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

# Verificar que existe raw_sequences
if [[ ! -d "$RAW_DIR" ]]; then
  echo "ERROR: No existe el directorio raw_sequences: $RAW_DIR"
  echo "Debe crear: $RAW_DIR con subdirectorios por grupo"
  exit 1
fi

# Detectar grupos automáticamente
echo "Detectando grupos de muestras..."
GRUPOS=($(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort))

if [[ ${#GRUPOS[@]} -eq 0 ]]; then
  echo "ERROR: No se encontraron subdirectorios en raw_sequences/"
  echo "Estructura esperada:"
  echo "  raw_sequences/"
  echo "    ├── Grupo1/"
  echo "    ├── Grupo2/"
  echo "    └── Grupo3/"
  exit 1
fi

echo "Grupos detectados: ${GRUPOS[@]}"
echo ""

# Verificar si ya existe metadata.tsv
if [[ -f "$METADATA_FILE" ]]; then
  echo "⚠ ADVERTENCIA: Ya existe $METADATA_FILE"
  echo ""
  read -p "¿Desea sobrescribirlo? (s/n): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Operación cancelada."
    exit 0
  fi
  echo ""
fi

# Crear encabezado
echo "Generando metadata.tsv..."
echo -e "#SampleID\tGroup" > "$METADATA_FILE"

# Contador de muestras
TOTAL_SAMPLES=0

# Recorrer cada grupo y extraer sample IDs
for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_RAW="$RAW_DIR/$GRUPO"
  
  echo "  Procesando grupo: $GRUPO"
  
  # Buscar archivos _1.fq.gz y extraer sample ID
  SAMPLES_IN_GROUP=0
  for fq1 in "$GRUPO_RAW"/*_1.fq.gz; do
    if [[ -f "$fq1" ]]; then
      basename_fq=$(basename "$fq1")
      sample_id="${basename_fq%_1.fq.gz}"
      
      # Verificar que existe el par R2
      fq2="${fq1/_1.fq.gz/_2.fq.gz}"
      if [[ ! -f "$fq2" ]]; then
        echo "    ⚠ ADVERTENCIA: Falta archivo R2 para $sample_id"
        continue
      fi
      
      # Agregar al metadata
      echo -e "${sample_id}\t${GRUPO}" >> "$METADATA_FILE"
      ((TOTAL_SAMPLES+=1))
      ((SAMPLES_IN_GROUP+=1))
    fi
  done
  
  echo "    → $SAMPLES_IN_GROUP muestras encontradas"
done

echo ""

# Verificar que se encontraron muestras
if [[ $TOTAL_SAMPLES -eq 0 ]]; then
  echo "ERROR: No se encontraron archivos *_1.fq.gz en raw_sequences/"
  rm -f "$METADATA_FILE"
  exit 1
fi

# Mostrar resumen
echo "=========================================="
echo "✓ Metadata generado exitosamente"
echo "=========================================="
echo ""
echo "Archivo: $METADATA_FILE"
echo "Total de muestras: $TOTAL_SAMPLES"
echo "Grupos: ${#GRUPOS[@]}"
echo ""
echo "Contenido del archivo:"
echo "----------------------------------------"
cat "$METADATA_FILE"
echo "----------------------------------------"
echo ""
echo "Puede editar manualmente este archivo si necesita:"
echo "  - Agregar columnas adicionales (edad, sexo, etc.)"
echo "  - Corregir nombres de grupos"
echo "  - Agregar metadatos específicos"
echo ""
echo "IMPORTANTE: Mantenga el formato TSV (tabulaciones)"
echo "y la columna 'Group' para los análisis de QIIME2"
echo ""