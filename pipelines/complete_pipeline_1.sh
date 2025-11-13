#!/usr/bin/env bash
################################################################################
# Pipeline completo de análisis de microbioma con QIIME2
# Incluye: Preprocesamiento con fastp, DADA2, filogenia y análisis de diversidad
# 
# Uso: bash qiime2_complete_pipeline.sh <nombre_proyecto> [config_file]
# Ejemplo: bash qiime2_complete_pipeline.sh Proyecto1_20241113
# Ejemplo con config: bash qiime2_complete_pipeline.sh Proyecto1_20241113 custom_config.sh
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURACIÓN DE PARÁMETROS - EDITABLE
# ============================================================================

# ---------------------------------------------------------------------------
# PARÁMETROS DE FASTP (Preprocesamiento de calidad)
# ---------------------------------------------------------------------------
# Trimming inicial (remover primers/adaptadores del inicio)
FASTP_TRIM_FRONT1=10        # Bases a recortar del inicio R1
FASTP_TRIM_FRONT2=10        # Bases a recortar del inicio R2

# Trimming de cola (remover bases de baja calidad del final)
FASTP_CUT_TAIL=true         # true/false - Activar corte de cola

# Filtrado por calidad
FASTP_QUALITY_PHRED=20      # Calidad mínima Phred (15-30 típico)
FASTP_LENGTH_REQUIRED=150   # Longitud mínima después de filtrado (100-250)

# Recursos computacionales
FASTP_THREADS=12            # Hilos para fastp (usar todos disponibles)

# Detección automática de adaptadores
FASTP_DETECT_ADAPTERS=true  # true/false - Detectar y remover adaptadores

# ---------------------------------------------------------------------------
# PARÁMETROS DE DADA2 (Denoising y corrección de errores)
# ---------------------------------------------------------------------------
# Trimming adicional (después de fastp, para región hipervariable específica)
DADA2_TRIM_LEFT_F=0         # Bases adicionales a remover de R1 (0-20)
DADA2_TRIM_LEFT_R=0         # Bases adicionales a remover de R2 (0-20)

# Truncamiento (longitud final de las lecturas)
# IMPORTANTE: Ajustar según región 16S (V3-V4, V4, etc.)
DADA2_TRUNC_LEN_F=230       # Longitud final R1 (220-250 para V3-V4)
DADA2_TRUNC_LEN_R=220       # Longitud final R2 (180-220 para V3-V4)

# Error esperado máximo (calidad)
DADA2_MAX_EE_F=2.0          # Max expected errors R1 (2.0-3.0)
DADA2_MAX_EE_R=2.0          # Max expected errors R2 (2.0-3.0)

# Recursos
DADA2_THREADS=2             # Hilos DADA2 (usar 1-2, más no mejora)

# ---------------------------------------------------------------------------
# PARÁMETROS DE ANÁLISIS DE DIVERSIDAD
# ---------------------------------------------------------------------------
# Profundidad de rarefacción (subsampling)
# CRÍTICO: Ajustar según profundidad de secuenciación
# Ver denoising-stats.qza para determinar valor óptimo
SAMPLING_DEPTH=6000         # Secuencias por muestra (5000-15000 típico)

# Recursos para construcción de árboles filogenéticos
PHYLO_THREADS=12            # Hilos para MAFFT/FastTree

# ---------------------------------------------------------------------------
# VARIABLES DE ENTORNO Y COMANDOS
# ---------------------------------------------------------------------------
export TMPDIR="/mnt/qiime2_tmp"
mkdir -p "$TMPDIR"

CONDA_RUN="/opt/conda/bin/conda run -n qiime2"
FASTP_RUN="/opt/conda/bin/conda run -n preproc fastp"
MULTIQC_RUN="/opt/conda/bin/conda run -n preproc multiqc"

# ============================================================================
# CARGAR CONFIGURACIÓN PERSONALIZADA (OPCIONAL)
# ============================================================================

if [[ $# -eq 2 ]] && [[ -f "$2" ]]; then
  echo "Cargando configuración personalizada: $2"
  source "$2"
  echo "✓ Configuración personalizada aplicada"
fi

# ============================================================================
# VERIFICACIÓN DE ARGUMENTOS Y ESTRUCTURA
# ============================================================================

if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo ""
  echo "Uso: bash $0 <nombre_proyecto> [config_file]"
  echo ""
  echo "Ejemplos:"
  echo "  bash $0 Proyecto1_20241113"
  echo "  bash $0 Proyecto1_20241113 custom_config.sh"
  echo ""
  echo "ARCHIVO DE CONFIGURACIÓN PERSONALIZADA (opcional):"
  echo "  El segundo parámetro permite sobrescribir los parámetros por defecto"
  echo "  sin modificar el script principal. Útil para probar diferentes"
  echo "  configuraciones de DADA2 o fastp."
  echo ""
  echo "  Ejemplo de custom_config.sh:"
  echo "    DADA2_TRUNC_LEN_F=250"
  echo "    DADA2_TRUNC_LEN_R=230"
  echo "    SAMPLING_DEPTH=8000"
  echo "    FASTP_QUALITY_PHRED=25"
  echo ""
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

# ============================================================================
# MOSTRAR CONFIGURACIÓN ACTUAL
# ============================================================================

echo ""
echo "=========================================="
echo "Pipeline QIIME2 - Análisis completo"
echo "=========================================="
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo ""
echo "CONFIGURACIÓN ACTUAL:"
echo "--------------------"
echo "FASTP:"
echo "  - Trim front F/R: $FASTP_TRIM_FRONT1 / $FASTP_TRIM_FRONT2"
echo "  - Cut tail: $FASTP_CUT_TAIL"
echo "  - Quality threshold: $FASTP_QUALITY_PHRED"
echo "  - Length required: $FASTP_LENGTH_REQUIRED"
echo "  - Threads: $FASTP_THREADS"
echo ""
echo "DADA2:"
echo "  - Trim left F/R: $DADA2_TRIM_LEFT_F / $DADA2_TRIM_LEFT_R"
echo "  - Truncate length F/R: $DADA2_TRUNC_LEN_F / $DADA2_TRUNC_LEN_R"
echo "  - Max EE F/R: $DADA2_MAX_EE_F / $DADA2_MAX_EE_R"
echo "  - Threads: $DADA2_THREADS"
echo ""
echo "DIVERSIDAD:"
echo "  - Sampling depth: $SAMPLING_DEPTH"
echo "  - Phylogeny threads: $PHYLO_THREADS"
echo ""

# Verificar directorio del proyecto
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

# Verificar raw_sequences
RAW_DIR="$PROJECT_DIR/raw_sequences"
if [[ ! -d "$RAW_DIR" ]]; then
  echo "ERROR: No existe el directorio raw_sequences: $RAW_DIR"
  echo "Debe existir: $RAW_DIR"
  exit 1
fi

# Detectar grupos automáticamente
echo "Detectando grupos de muestras..."
GRUPOS=()
while IFS= read -r dir; do
  GRUPOS+=("$(basename "$dir")")
done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#GRUPOS[@]} -eq 0 ]]; then
  echo "ERROR: No se encontraron subdirectorios en raw_sequences/"
  exit 1
fi

echo "Grupos detectados: ${GRUPOS[@]}"
echo ""

# Crear estructura de directorios
PREPROC_DIR="$PROJECT_DIR/preproc"
QIIME_DIR="$PROJECT_DIR/qiime2_results"
RESULTS_DIR="$PROJECT_DIR/results"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

mkdir -p "$PREPROC_DIR"
mkdir -p "$QIIME_DIR"
mkdir -p "$RESULTS_DIR"

# ============================================================================
# GENERAR METADATA AUTOMÁTICAMENTE (CON VERIFICACIÓN PREVIA)
# ============================================================================

echo "=========================================="
echo "Verificando archivo metadata.tsv..."
echo "=========================================="

# Verificar si ya existe metadata.tsv
if [[ -f "$METADATA_FILE" ]]; then
  echo "ADVERTENCIA: Ya existe un archivo metadata.tsv"
  echo ""
  cat "$METADATA_FILE"
  # echo ""
  # read -p "¿Desea sobrescribir el metadata existente? (s/N): " -n 1 -r
  # echo ""
  
  # if [[ ! $REPLY =~ ^[Ss]$ ]]; then
  #   echo "✓ Conservando metadata.tsv existente"
  #   echo ""
  # else
  #   echo "Regenerando metadata.tsv..."
  #   rm "$METADATA_FILE"
  # fi
fi

# Generar metadata solo si no existe o fue eliminado

# Mostrar metadata final
echo ""
echo "Contenido de metadata.tsv:"
echo "-------------------------"
cat "$METADATA_FILE"
echo ""

# Contar muestras del metadata
TOTAL_SAMPLES=$(grep -v "^#SampleID" "$METADATA_FILE" | wc -l)
echo "Total de muestras en metadata: $TOTAL_SAMPLES"
echo ""

# ============================================================================
# PASO 1: PREPROCESAMIENTO CON FASTP
# ============================================================================

echo "=========================================="
echo "PASO 1: Preprocesamiento con fastp"
echo "=========================================="
echo ""

for GRUPO in "${GRUPOS[@]}"; do
  echo "----------------------------------------"
  echo "Procesando grupo: $GRUPO"
  echo "----------------------------------------"
  
  GRUPO_RAW="$RAW_DIR/$GRUPO"
  GRUPO_PREPROC="$PREPROC_DIR/$GRUPO"
  mkdir -p "$GRUPO_PREPROC"
  
  # Procesar cada par de archivos
  while IFS= read -r fq1; do
    if [[ ! -f "$fq1" ]]; then
      continue
    fi
    
    # Obtener archivos forward y reverse
    fq2="${fq1/_1.fq.gz/_2.fq.gz}"
    
    if [[ ! -f "$fq2" ]]; then
      echo "  ⚠️  ADVERTENCIA: No se encontró el par reverse para $(basename "$fq1")"
      continue
    fi
    
    # Nombres de salida
    basename_fq=$(basename "$fq1" _1.fq.gz)
    out1="$GRUPO_PREPROC/${basename_fq}_filtered_1.fq.gz"
    out2="$GRUPO_PREPROC/${basename_fq}_filtered_2.fq.gz"
    html_report="$GRUPO_PREPROC/${basename_fq}_fastp.html"
    json_report="$GRUPO_PREPROC/${basename_fq}_fastp.json"
    log_file="$GRUPO_PREPROC/${basename_fq}_fastp.log"
    
    echo "  Procesando: $basename_fq"
    
    # Construir comando fastp con parámetros configurables
    FASTP_CMD="$FASTP_RUN \
      --in1 \"$fq1\" \
      --in2 \"$fq2\" \
      --out1 \"$out1\" \
      --out2 \"$out2\" \
      --html \"$html_report\" \
      --json \"$json_report\" \
      --report_title \"$basename_fq Fastp Report\" \
      --thread $FASTP_THREADS \
      --qualified_quality_phred $FASTP_QUALITY_PHRED \
      --length_required $FASTP_LENGTH_REQUIRED"
    
    # Agregar parámetros opcionales
    if [[ "$FASTP_DETECT_ADAPTERS" == "true" ]]; then
      FASTP_CMD="$FASTP_CMD --detect_adapter_for_pe"
    fi
    
    if [[ $FASTP_TRIM_FRONT1 -gt 0 ]]; then
      FASTP_CMD="$FASTP_CMD --trim_front1 $FASTP_TRIM_FRONT1"
    fi
    
    if [[ $FASTP_TRIM_FRONT2 -gt 0 ]]; then
      FASTP_CMD="$FASTP_CMD --trim_front2 $FASTP_TRIM_FRONT2"
    fi
    
    if [[ "$FASTP_CUT_TAIL" == "true" ]]; then
      FASTP_CMD="$FASTP_CMD --cut_tail"
    fi
    
    # Ejecutar fastp
    eval $FASTP_CMD &> "$log_file"
    
    if [[ $? -eq 0 ]]; then
      # Extraer estadísticas del log
      reads_before=$(grep "total reads:" "$log_file" | head -1 | awk '{print $3}')
      reads_after=$(grep "total reads:" "$log_file" | tail -1 | awk '{print $3}')
      echo "    Reads antes: $reads_before → después: $reads_after"
    else
      echo "    ⚠️  ERROR en fastp para $basename_fq"
    fi
  done < <(find "$GRUPO_RAW" -maxdepth 1 -name "*_1.fq.gz" -type f)
  
  echo "  ✓ Grupo $GRUPO completado"
  echo ""
done

# Generar reporte MultiQC
echo "Generando reporte consolidado con MultiQC..."
$MULTIQC_RUN "$PREPROC_DIR" -o "$PREPROC_DIR/multiqc_report" -n multiqc_fastp_report --force 2>/dev/null || echo "  ⚠️  MultiQC no disponible o falló"

echo ""
echo "✓ Preprocesamiento completado para todos los grupos"
echo "  Reporte MultiQC: $PREPROC_DIR/multiqc_report/multiqc_fastp_report.html"
echo ""

# ============================================================================
# PASO 2: DADA2 DENOISING POR GRUPO
# ============================================================================

echo "=========================================="
echo "PASO 2: DADA2 - Denoising por grupo"
echo "=========================================="
echo ""

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

for GRUPO in "${GRUPOS[@]}"; do
  echo "----------------------------------------"
  echo "Ejecutando DADA2 para: $GRUPO"
  echo "----------------------------------------"
  
  GRUPO_INPUT="$PREPROC_DIR/$GRUPO"
  GRUPO_OUT="$BASE_DADA2/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  MANIFEST="$GRUPO_OUT/manifest.tsv"
  DEMUX="$GRUPO_OUT/demux-paired.qza"
  
  # Crear manifest
  echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > "$MANIFEST"
  
  while IFS= read -r f; do
    if [[ -f "$f" ]]; then
      id=$(basename "$f" | sed 's/_filtered_1\.fq\.gz$//')
      rev="${f/_filtered_1/_filtered_2}"
      echo -e "$id\t$f\t$rev" >> "$MANIFEST"
    fi
  done < <(find "$GRUPO_INPUT" -maxdepth 1 -name "*_filtered_1.fq.gz" -type f)
  
  # Contar muestras
  NUM_SAMPLES=$(grep -v "^sample-id" "$MANIFEST" | wc -l)
  echo "  Muestras en manifest: $NUM_SAMPLES"
  
  if [[ $NUM_SAMPLES -eq 0 ]]; then
    echo "  ⚠️  ADVERTENCIA: No se encontraron muestras para $GRUPO"
    continue
  fi
  
  # Importar datos
  echo "  Importando datos a QIIME2..."
  $CONDA_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --output-path "$DEMUX" \
    --input-format PairedEndFastqManifestPhred33V2
  
  # Denoising con DADA2
  echo "  Ejecutando denoising (esto puede tomar varios minutos)..."
  $CONDA_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$DEMUX" \
    --p-trim-left-f $DADA2_TRIM_LEFT_F \
    --p-trim-left-r $DADA2_TRIM_LEFT_R \
    --p-trunc-len-f $DADA2_TRUNC_LEN_F \
    --p-trunc-len-r $DADA2_TRUNC_LEN_R \
    --p-max-ee-f $DADA2_MAX_EE_F \
    --p-max-ee-r $DADA2_MAX_EE_R \
    --p-n-threads $DADA2_THREADS \
    --o-table "$GRUPO_OUT/table.qza" \
    --o-representative-sequences "$GRUPO_OUT/rep-seqs.qza" \
    --o-denoising-stats "$GRUPO_OUT/denoising-stats.qza" \
    --verbose
  
  # Generar visualización de estadísticas
  $CONDA_RUN qiime metadata tabulate \
    --m-input-file "$GRUPO_OUT/denoising-stats.qza" \
    --o-visualization "$GRUPO_OUT/denoising-stats.qzv"
  
  echo "  ✓ DADA2 completado para $GRUPO"
  echo "    - Tabla: $GRUPO_OUT/table.qza"
  echo "    - Secuencias: $GRUPO_OUT/rep-seqs.qza"
  echo "    - Stats: $GRUPO_OUT/denoising-stats.qzv"
  echo ""
done

echo "✓ DADA2 completado para todos los grupos"
echo ""

# ============================================================================
# PASO 3: CONSTRUCCIÓN DE ÁRBOLES FILOGENÉTICOS POR GRUPO
# ============================================================================

echo "=========================================="
echo "PASO 3: Construcción de árboles filogenéticos"
echo "=========================================="
echo ""

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

for GRUPO in "${GRUPOS[@]}"; do
  echo "----------------------------------------"
  echo "Construyendo árbol para: $GRUPO"
  echo "----------------------------------------"
  
  GRUPO_OUT="$BASE_PHYLO/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  # Verificar que existe el archivo de secuencias
  if [[ ! -f "$BASE_DADA2/$GRUPO/rep-seqs.qza" ]]; then
    echo "  ⚠️  ADVERTENCIA: No se encontró rep-seqs.qza para $GRUPO"
    continue
  fi
  
  $CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences "$BASE_DADA2/$GRUPO/rep-seqs.qza" \
    --p-n-threads $PHYLO_THREADS \
    --o-alignment "$GRUPO_OUT/aligned-rep-seqs.qza" \
    --o-masked-alignment "$GRUPO_OUT/masked-aligned-rep-seqs.qza" \
    --o-tree "$GRUPO_OUT/unrooted-tree.qza" \
    --o-rooted-tree "$GRUPO_OUT/rooted-tree.qza" \
    --verbose
  
  echo "  ✓ Árbol generado para $GRUPO"
  echo ""
done

echo "✓ Árboles filogenéticos completados"
echo ""

# ============================================================================
# PASO 4: ANÁLISIS DE DIVERSIDAD COMPARATIVO
# ============================================================================

echo "=========================================="
echo "PASO 4: Análisis de diversidad comparativo"
echo "=========================================="
echo ""

OUT_DIV="$QIIME_DIR/core_diversity"
COMBINED_OUT="$OUT_DIV/combined_analysis"

# Limpiar resultados previos
if [[ -d "$COMBINED_OUT" ]]; then
  rm -rf "$COMBINED_OUT"
fi
mkdir -p "$COMBINED_OUT"

# Paso 4.1: Combinar tablas
echo "Paso 4.1: Combinando tablas de feature..."

MERGE_TABLES_CMD="$CONDA_RUN qiime feature-table merge"
for GRUPO in "${GRUPOS[@]}"; do
  if [[ -f "$BASE_DADA2/$GRUPO/table.qza" ]]; then
    MERGE_TABLES_CMD="$MERGE_TABLES_CMD --i-tables $BASE_DADA2/$GRUPO/table.qza"
  fi
done
MERGE_TABLES_CMD="$MERGE_TABLES_CMD --o-merged-table $COMBINED_OUT/merged_table.qza"

eval $MERGE_TABLES_CMD

echo "  ✓ Tablas combinadas"
echo ""

# Paso 4.2: Combinar secuencias representativas
echo "Paso 4.2: Combinando secuencias representativas..."

MERGE_SEQS_CMD="$CONDA_RUN qiime feature-table merge-seqs"
for GRUPO in "${GRUPOS[@]}"; do
  if [[ -f "$BASE_DADA2/$GRUPO/rep-seqs.qza" ]]; then
    MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
  fi
done
MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"

eval $MERGE_SEQS_CMD

echo "  ✓ Secuencias combinadas"
echo ""

# Paso 4.3: Generar árbol filogenético combinado
echo "Paso 4.3: Generando árbol filogenético combinado..."
echo "  (esto puede tomar 5-15 minutos dependiendo del número de ASVs)"

$CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences "$COMBINED_OUT/merged_rep-seqs.qza" \
  --p-n-threads $PHYLO_THREADS \
  --o-alignment "$COMBINED_OUT/aligned-rep-seqs.qza" \
  --o-masked-alignment "$COMBINED_OUT/masked-aligned-rep-seqs.qza" \
  --o-tree "$COMBINED_OUT/unrooted-tree.qza" \
  --o-rooted-tree "$COMBINED_OUT/rooted-tree.qza" \
  --verbose

echo "  ✓ Árbol filogenético combinado generado"
echo ""

# Paso 4.4: Core metrics phylogenetic
echo "Paso 4.4: Ejecutando core-metrics-phylogenetic..."
echo "  Sampling depth: $SAMPLING_DEPTH"

$CONDA_RUN qiime diversity core-metrics-phylogenetic \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir "$COMBINED_OUT/results" \
  --verbose

echo "  ✓ Core metrics completados"
echo ""

# Paso 4.5: Alpha group significance
echo "Paso 4.5: Análisis de significancia - Alfa diversidad..."

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    echo "  Procesando: $metric"
    $CONDA_RUN qiime diversity alpha-group-significance \
      --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
    
    if [[ $? -eq 0 ]]; then
      echo "    ✓ $metric completado"
    fi
  fi
done
echo ""

# Paso 4.6: Beta group significance
echo "Paso 4.6: Análisis de significancia - Beta diversidad..."

for metric in unweighted_unifrac weighted_unifrac bray_curtis jaccard; do
  if [[ -f "$COMBINED_OUT/results/${metric}_distance_matrix.qza" ]]; then
    echo "  Procesando: $metric"
    $CONDA_RUN qiime diversity beta-group-significance \
      --i-distance-matrix "$COMBINED_OUT/results/${metric}_distance_matrix.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --m-metadata-column Group \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv" \
      --p-pairwise
    
    if [[ $? -eq 0 ]]; then
      echo "    ✓ $metric completado"
    fi
  fi
done
echo ""

# Paso 4.7: Alpha rarefaction
echo "Paso 4.7: Curvas de rarefacción..."

$CONDA_RUN qiime diversity alpha-rarefaction \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-max-depth $SAMPLING_DEPTH \
  --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

echo "  ✓ Rarefacción completada"
echo ""

echo "✓ Análisis de diversidad completado"
echo ""

# ============================================================================
# PASO 5: COPIAR VISUALIZACIONES FINALES A RESULTS
# ============================================================================

echo "=========================================="
echo "PASO 5: Copiando visualizaciones finales"
echo "=========================================="

# Copiar denoising stats de cada grupo
for GRUPO in "${GRUPOS[@]}"; do
  if [[ -f "$BASE_DADA2/$GRUPO/denoising-stats.qzv" ]]; then
    cp "$BASE_DADA2/$GRUPO/denoising-stats.qzv" "$RESULTS_DIR/denoising-stats-${GRUPO}.qzv"
  fi
done

# Copiar todos los archivos .qzv de análisis de diversidad
echo "Copiando archivos de análisis de diversidad..."
find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

# Contar archivos copiados
NUM_QZV=$(ls -1 "$RESULTS_DIR"/*.qzv 2>/dev/null | wc -l)
echo "  ✓ $NUM_QZV visualizaciones copiadas a results/"

# Listar archivos finales
echo ""
echo "Visualizaciones disponibles en $RESULTS_DIR:"
ls -1 "$RESULTS_DIR"/*.qzv 2>/dev/null | xargs -n 1 basename | sort || echo "  (Ninguna visualización generada)"

echo ""

# ============================================================================
# RESUMEN FINAL Y RECOMENDACIONES
# ============================================================================

echo "=========================================="
echo "✓ PIPELINE COMPLETADO EXITOSAMENTE"
echo "=========================================="
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Ubicación: $PROJECT_DIR"
echo ""
echo "Estructura generada:"
echo "  ├── raw_sequences/          (datos originales)"
echo "  ├── preproc/                (secuencias filtradas con fastp)"
echo "  │   └── multiqc_report/     (reporte de calidad consolidado)"
echo "  ├── qiime2_results/"
echo "  │   ├── dada2/              (tablas y secuencias por grupo)"
echo "  │   ├── phylogeny/          (árboles por grupo)"
echo "  │   └── core_diversity/     (análisis comparativo)"
echo "  ├── results/                (visualizaciones .qzv)"
echo "  └── metadata.tsv            (información de muestras)"
echo ""
echo "Grupos analizados: ${GRUPOS[@]}"
echo "Total de muestras: $TOTAL_SAMPLES"
echo "Número de visualizaciones: $NUM_QZV"
echo ""
echo "PRÓXIMOS PASOS:"
echo "---------------"
echo "1. Revisar denoising-stats-*.qzv para verificar calidad del filtrado"
echo "   → Si muchas muestras se pierden, ajustar SAMPLING_DEPTH"
echo ""
echo "2. Visualizar resultados en: https://view.qiime2.org"
echo "   → Subir archivos .qzv desde: $RESULTS_DIR/"
echo ""
echo "3. Si necesitas ajustar parámetros, crea un archivo de configuración:"
echo "   → Ejemplo: crear custom_config.sh con:"
echo ""
echo "     # custom_config.sh"
echo "     DADA2_TRUNC_LEN_F=250"
echo "     DADA2_TRUNC_LEN_R=230"
echo "     SAMPLING_DEPTH=8000"
echo "     FASTP_QUALITY_PHRED=25"
echo ""
echo "   → Luego ejecuta: bash $0 $PROJECT_NAME custom_config.sh"
echo ""
echo "Archivos clave:"
echo "  - Metadata: $METADATA_FILE"
echo "  - Tabla combinada: $COMBINED_OUT/merged_table.qza"
echo "  - Árbol filogenético: $COMBINED_OUT/rooted-tree.qza"
echo "  - Visualizaciones: $RESULTS_DIR/*.qzv"
echo "  - Reporte QC: $PREPROC_DIR/multiqc_report/multiqc_fastp_report.html"
echo ""
echo "=========================================="