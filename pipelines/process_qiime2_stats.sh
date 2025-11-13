#!/usr/bin/env bash
################################################################################
# Pipeline completo de análisis de microbioma con monitoreo de recursos
# Incluye: Preprocesamiento, DADA2, filogenia, diversidad + métricas de rendimiento
# 
# Uso: bash qiime2_pipeline_monitored.sh <nombre_proyecto> [config_file]
# Ejemplo: bash qiime2_pipeline_monitored.sh Proyecto1_20241113
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURACIÓN DE PARÁMETROS - EDITABLE
# ============================================================================

# Parámetros FASTP
FASTP_TRIM_FRONT1=10
FASTP_TRIM_FRONT2=10
FASTP_CUT_TAIL=true
FASTP_QUALITY_PHRED=20
FASTP_LENGTH_REQUIRED=150
FASTP_THREADS=12
FASTP_DETECT_ADAPTERS=true

# Parámetros DADA2
DADA2_TRIM_LEFT_F=0
DADA2_TRIM_LEFT_R=0
DADA2_TRUNC_LEN_F=230
DADA2_TRUNC_LEN_R=220
DADA2_MAX_EE_F=2.0
DADA2_MAX_EE_R=2.0
DADA2_THREADS=12

# Parámetros de diversidad
SAMPLING_DEPTH=6000
PHYLO_THREADS=12

# Variables de entorno
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
fi

# ============================================================================
# VERIFICACIÓN DE ARGUMENTOS
# ============================================================================

if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto> [config_file]"
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

# ============================================================================
# CONFIGURACIÓN DE MONITOREO
# ============================================================================

# Crear directorio de logs y métricas
LOGS_DIR="$PROJECT_DIR/logs"
METRICS_DIR="$PROJECT_DIR/metrics"
mkdir -p "$LOGS_DIR"
mkdir -p "$METRICS_DIR"

# Archivos de salida
MASTER_LOG="$LOGS_DIR/pipeline_master.log"
TIMING_LOG="$LOGS_DIR/timing_summary.csv"
DSTAT_CSV="$METRICS_DIR/system_metrics.csv"

# Inicializar archivos
echo "step,start_time,end_time,duration_seconds,max_memory_kb,cpu_percent,exit_status" > "$TIMING_LOG"

# Función para iniciar monitoreo de un paso
start_monitoring() {
  local STEP_NAME=$1
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_METRICS="$METRICS_DIR/${STEP_NAME}_dstat.csv"
  
  # Iniciar dstat para este paso
  dstat -tcmnd --output "$STEP_METRICS" 1 > /dev/null 2>&1 &
  local DSTAT_PID=$!
  
  # Guardar timestamp de inicio
  local START_TIME=$(date +%s)
  
  # Retornar PIDs y archivos
  echo "$DSTAT_PID|$START_TIME|$STEP_LOG|$STEP_TIME|$STEP_METRICS"
}

# Función para detener monitoreo de un paso
stop_monitoring() {
  local STEP_NAME=$1
  local MONITOR_INFO=$2
  local EXIT_CODE=$3
  
  # Parsear información
  IFS='|' read -r DSTAT_PID START_TIME STEP_LOG STEP_TIME STEP_METRICS <<< "$MONITOR_INFO"
  
  # Detener dstat
  kill $DSTAT_PID 2>/dev/null || true
  wait $DSTAT_PID 2>/dev/null || true
  
  # Calcular duración
  local END_TIME=$(date +%s)
  local DURATION=$((END_TIME - START_TIME))
  
  # Extraer métricas del log de time
  local MAX_MEM="N/A"
  local CPU_PERCENT="N/A"
  if [[ -f "$STEP_TIME" ]]; then
    MAX_MEM=$(grep "Maximum resident set size" "$STEP_TIME" | awk '{print $6}' || echo "N/A")
    CPU_PERCENT=$(grep "Percent of CPU" "$STEP_TIME" | awk '{print $7}' | tr -d '%' || echo "N/A")
  fi
  
  # Guardar en resumen
  echo "$STEP_NAME,$(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S'),$(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S'),$DURATION,$MAX_MEM,$CPU_PERCENT,$EXIT_CODE" >> "$TIMING_LOG"
  
  # Mostrar resumen
  echo "  Duración: ${DURATION}s | Memoria máx: ${MAX_MEM}KB | CPU: ${CPU_PERCENT}%"
}

# Función para ejecutar comando con monitoreo
run_monitored() {
  local STEP_NAME=$1
  shift
  local COMMAND="$@"
  
  echo ""
  echo "=========================================="
  echo "Ejecutando: $STEP_NAME"
  echo "=========================================="
  
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"
  
  # Iniciar monitoreo
  local MONITOR_INFO=$(start_monitoring "$STEP_NAME")
  
  # Ejecutar comando con /usr/bin/time
  set +e
  /usr/bin/time -v bash -c "$COMMAND" > "$STEP_LOG" 2> "$STEP_TIME"
  local EXIT_CODE=$?
  set -e
  
  # Detener monitoreo
  stop_monitoring "$STEP_NAME" "$MONITOR_INFO" "$EXIT_CODE"
  
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "ERROR: $STEP_NAME falló con código $EXIT_CODE"
    echo "Ver logs en: $STEP_LOG"
    return $EXIT_CODE
  fi
  
  echo "✓ $STEP_NAME completado"
  return 0
}

# ============================================================================
# INICIO DEL PIPELINE
# ============================================================================

echo ""
echo "=========================================="
echo "Pipeline QIIME2 con Monitoreo"
echo "=========================================="
echo "Proyecto: $PROJECT_NAME"
echo "Hora de inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Logs: $LOGS_DIR"
echo "Métricas: $METRICS_DIR"
echo ""

# Timestamp de inicio global
PIPELINE_START=$(date +%s)

# ============================================================================
# VERIFICACIÓN DE ESTRUCTURA
# ============================================================================

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

RAW_DIR="$PROJECT_DIR/raw_sequences"
if [[ ! -d "$RAW_DIR" ]]; then
  echo "ERROR: No existe raw_sequences: $RAW_DIR"
  exit 1
fi

# Detectar grupos
GRUPOS=($(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort))
if [[ ${#GRUPOS[@]} -eq 0 ]]; then
  echo "ERROR: No se encontraron subdirectorios en raw_sequences/"
  exit 1
fi

echo "Grupos detectados: ${GRUPOS[@]}"
echo ""

# Crear estructura
PREPROC_DIR="$PROJECT_DIR/preproc"
QIIME_DIR="$PROJECT_DIR/qiime2_results"
RESULTS_DIR="$PROJECT_DIR/results"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

mkdir -p "$PREPROC_DIR"
mkdir -p "$QIIME_DIR"
mkdir -p "$RESULTS_DIR"

# ============================================================================
# VERIFICAR METADATA
# ============================================================================

if [[ ! -f "$METADATA_FILE" ]]; then
  echo "=========================================="
  echo "ERROR: No existe metadata.tsv"
  echo "=========================================="
  echo ""
  echo "El archivo metadata.tsv no fue encontrado en:"
  echo "  $METADATA_FILE"
  echo ""
  echo "Por favor, genérelo usando el script:"
  echo "  bash generate_metadata.sh $PROJECT_NAME"
  echo ""
  echo "Luego vuelva a ejecutar este pipeline."
  echo ""
  exit 1
fi

echo "✓ Metadata encontrado: $METADATA_FILE"
echo ""

# ============================================================================
# PASO 1: PREPROCESAMIENTO CON FASTP
# ============================================================================

for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_RAW="$RAW_DIR/$GRUPO"
  GRUPO_PREPROC="$PREPROC_DIR/$GRUPO"
  mkdir -p "$GRUPO_PREPROC"
  
  for fq1 in "$GRUPO_RAW"/*_1.fq.gz; do
    if [[ ! -f "$fq1" ]]; then
      continue
    fi
    
    fq2="${fq1/_1.fq.gz/_2.fq.gz}"
    if [[ ! -f "$fq2" ]]; then
      continue
    fi
    
    basename_fq=$(basename "$fq1" _1.fq.gz)
    out1="$GRUPO_PREPROC/${basename_fq}_filtered_1.fq.gz"
    out2="$GRUPO_PREPROC/${basename_fq}_filtered_2.fq.gz"
    html_report="$GRUPO_PREPROC/${basename_fq}_fastp.html"
    json_report="$GRUPO_PREPROC/${basename_fq}_fastp.json"
    
    FASTP_CMD="$FASTP_RUN \
      --in1 '$fq1' --in2 '$fq2' \
      --out1 '$out1' --out2 '$out2' \
      --html '$html_report' --json '$json_report' \
      --report_title '$basename_fq Fastp Report' \
      --thread $FASTP_THREADS \
      --qualified_quality_phred $FASTP_QUALITY_PHRED \
      --length_required $FASTP_LENGTH_REQUIRED"
    
    [[ "$FASTP_DETECT_ADAPTERS" == "true" ]] && FASTP_CMD="$FASTP_CMD --detect_adapter_for_pe"
    [[ $FASTP_TRIM_FRONT1 -gt 0 ]] && FASTP_CMD="$FASTP_CMD --trim_front1 $FASTP_TRIM_FRONT1"
    [[ $FASTP_TRIM_FRONT2 -gt 0 ]] && FASTP_CMD="$FASTP_CMD --trim_front2 $FASTP_TRIM_FRONT2"
    [[ "$FASTP_CUT_TAIL" == "true" ]] && FASTP_CMD="$FASTP_CMD --cut_tail"
    
    run_monitored "fastp_${GRUPO}_${basename_fq}" "$FASTP_CMD"
  done
done

# MultiQC
run_monitored "multiqc_fastp" "$MULTIQC_RUN '$PREPROC_DIR' -o '$PREPROC_DIR/multiqc_report' -n multiqc_fastp_report --force"

# ============================================================================
# PASO 2: DADA2 DENOISING
# ============================================================================

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_INPUT="$PREPROC_DIR/$GRUPO"
  GRUPO_OUT="$BASE_DADA2/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  MANIFEST="$GRUPO_OUT/manifest.tsv"
  DEMUX="$GRUPO_OUT/demux-paired.qza"
  
  # Crear manifest
  echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > "$MANIFEST"
  for f in "$GRUPO_INPUT"/*_filtered_1.fq.gz; do
    [[ ! -f "$f" ]] && continue
    id=$(basename "$f" | sed 's/_filtered_1\.fq\.gz$//')
    rev="${f/_filtered_1/_filtered_2}"
    echo -e "$id\t$f\t$rev" >> "$MANIFEST"
  done
  
  # Importar (sin monitoreo intensivo)
  echo "Importando datos para $GRUPO..."
  $CONDA_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --output-path "$DEMUX" \
    --input-format PairedEndFastqManifestPhred33V2
  
  # DADA2 (CON monitoreo)
  DADA2_CMD="$CONDA_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs '$DEMUX' \
    --p-trim-left-f $DADA2_TRIM_LEFT_F \
    --p-trim-left-r $DADA2_TRIM_LEFT_R \
    --p-trunc-len-f $DADA2_TRUNC_LEN_F \
    --p-trunc-len-r $DADA2_TRUNC_LEN_R \
    --p-max-ee-f $DADA2_MAX_EE_F \
    --p-max-ee-r $DADA2_MAX_EE_R \
    --p-n-threads $DADA2_THREADS \
    --o-table '$GRUPO_OUT/table.qza' \
    --o-representative-sequences '$GRUPO_OUT/rep-seqs.qza' \
    --o-denoising-stats '$GRUPO_OUT/denoising-stats.qza' \
    --verbose"
  
  run_monitored "dada2_${GRUPO}" "$DADA2_CMD"
  
  # Visualización de stats
  $CONDA_RUN qiime metadata tabulate \
    --m-input-file "$GRUPO_OUT/denoising-stats.qza" \
    --o-visualization "$GRUPO_OUT/denoising-stats.qzv"
done

# ============================================================================
# PASO 3: ÁRBOLES FILOGENÉTICOS POR GRUPO
# ============================================================================

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_OUT="$BASE_PHYLO/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  PHYLO_CMD="$CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences '$BASE_DADA2/$GRUPO/rep-seqs.qza' \
    --p-n-threads $PHYLO_THREADS \
    --o-alignment '$GRUPO_OUT/aligned-rep-seqs.qza' \
    --o-masked-alignment '$GRUPO_OUT/masked-aligned-rep-seqs.qza' \
    --o-tree '$GRUPO_OUT/unrooted-tree.qza' \
    --o-rooted-tree '$GRUPO_OUT/rooted-tree.qza' \
    --verbose"
  
  run_monitored "phylogeny_${GRUPO}" "$PHYLO_CMD"
done

# ============================================================================
# PASO 4: ANÁLISIS DE DIVERSIDAD COMPARATIVO
# ============================================================================

OUT_DIV="$QIIME_DIR/core_diversity"
COMBINED_OUT="$OUT_DIV/combined_analysis"
rm -rf "$COMBINED_OUT"
mkdir -p "$COMBINED_OUT"

# Combinar tablas
MERGE_TABLES_CMD="$CONDA_RUN qiime feature-table merge"
for GRUPO in "${GRUPOS[@]}"; do
  MERGE_TABLES_CMD="$MERGE_TABLES_CMD --i-tables $BASE_DADA2/$GRUPO/table.qza"
done
MERGE_TABLES_CMD="$MERGE_TABLES_CMD --o-merged-table $COMBINED_OUT/merged_table.qza"

run_monitored "merge_tables" "$MERGE_TABLES_CMD"

# Combinar secuencias
MERGE_SEQS_CMD="$CONDA_RUN qiime feature-table merge-seqs"
for GRUPO in "${GRUPOS[@]}"; do
  MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
done
MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"

run_monitored "merge_sequences" "$MERGE_SEQS_CMD"

# Árbol combinado
PHYLO_COMBINED_CMD="$CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences '$COMBINED_OUT/merged_rep-seqs.qza' \
  --p-n-threads $PHYLO_THREADS \
  --o-alignment '$COMBINED_OUT/aligned-rep-seqs.qza' \
  --o-masked-alignment '$COMBINED_OUT/masked-aligned-rep-seqs.qza' \
  --o-tree '$COMBINED_OUT/unrooted-tree.qza' \
  --o-rooted-tree '$COMBINED_OUT/rooted-tree.qza' \
  --verbose"

run_monitored "phylogeny_combined" "$PHYLO_COMBINED_CMD"

# Core metrics
CORE_METRICS_CMD="$CONDA_RUN qiime diversity core-metrics-phylogenetic \
  --i-table '$COMBINED_OUT/merged_table.qza' \
  --i-phylogeny '$COMBINED_OUT/rooted-tree.qza' \
  --m-metadata-file '$METADATA_FILE' \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir '$COMBINED_OUT/results' \
  --verbose"

run_monitored "core_metrics" "$CORE_METRICS_CMD"

# Alpha/Beta significance (sin monitoreo detallado)
echo ""
echo "Ejecutando análisis de significancia..."

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    $CONDA_RUN qiime diversity alpha-group-significance \
      --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
  fi
done

for metric in unweighted_unifrac weighted_unifrac bray_curtis jaccard; do
  if [[ -f "$COMBINED_OUT/results/${metric}_distance_matrix.qza" ]]; then
    $CONDA_RUN qiime diversity beta-group-significance \
      --i-distance-matrix "$COMBINED_OUT/results/${metric}_distance_matrix.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --m-metadata-column Group \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv" \
      --p-pairwise
  fi
done

# Alpha rarefaction
$CONDA_RUN qiime diversity alpha-rarefaction \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-max-depth $SAMPLING_DEPTH \
  --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

# ============================================================================
# COPIAR VISUALIZACIONES
# ============================================================================

echo ""
echo "Copiando visualizaciones a results/..."
for GRUPO in "${GRUPOS[@]}"; do
  [[ -f "$BASE_DADA2/$GRUPO/denoising-stats.qzv" ]] && \
    cp "$BASE_DADA2/$GRUPO/denoising-stats.qzv" "$RESULTS_DIR/denoising-stats-${GRUPO}.qzv"
done
find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \;

# ============================================================================
# RESUMEN FINAL
# ============================================================================

PIPELINE_END=$(date +%s)
TOTAL_DURATION=$((PIPELINE_END - PIPELINE_START))
HOURS=$((TOTAL_DURATION / 3600))
MINUTES=$(((TOTAL_DURATION % 3600) / 60))
SECONDS=$((TOTAL_DURATION % 60))

echo ""
echo "=========================================="
echo "✓ PIPELINE COMPLETADO"
echo "=========================================="
echo ""
echo "Hora de finalización: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Duración total: ${HOURS}h ${MINUTES}m ${SECONDS}s"
echo ""
echo "Archivos de monitoreo:"
echo "  - Resumen de tiempos: $TIMING_LOG"
echo "  - Logs detallados: $LOGS_DIR/"
echo "  - Métricas del sistema: $METRICS_DIR/"
echo ""
echo "Para generar gráficos, ejecute:"
echo "  bash generate_plots.sh $PROJECT_NAME"
echo ""