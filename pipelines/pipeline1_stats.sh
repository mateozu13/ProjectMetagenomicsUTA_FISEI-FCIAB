#!/usr/bin/env bash
################################################################################
# Pipeline completo de análisis de microbioma con monitoreo COMPLETO de recursos
# Incluye: Preprocesamiento, DADA2, filogenia, diversidad + métricas detalladas
# Métricas: CPU, Memoria, I/O de disco, Red, Tiempo total y por paso
# 
# Uso: bash pipeline1_stats.sh <nombre_proyecto> [config_file]
# Ejemplo: bash pipeline1_stats.sh Proyecto1_20251113
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURACIÓN DE PARÁMETROS
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

LOGS_DIR="$PROJECT_DIR/logs"
METRICS_DIR="$PROJECT_DIR/metrics"
mkdir -p "$LOGS_DIR"
mkdir -p "$METRICS_DIR"

MASTER_LOG="$LOGS_DIR/pipeline_master.log"
TIMING_LOG="$LOGS_DIR/timing_summary.csv"
SYSTEM_SUMMARY="$METRICS_DIR/system_summary.csv"
PIPELINE_SUMMARY="$METRICS_DIR/pipeline_summary.txt"

# Inicializar CSV
echo "step,start_time,end_time,duration_seconds,duration_minutes,max_memory_kb,max_memory_mb,max_memory_gb,cpu_percent,io_read_mb,io_write_mb,io_total_mb,exit_status" > "$TIMING_LOG"

echo "timestamp,step,cpu_user,cpu_system,cpu_idle,memory_used_mb,memory_free_mb,disk_read_mb,disk_write_mb" > "$SYSTEM_SUMMARY"

declare -A STEP_IO_READ
declare -A STEP_IO_WRITE
PIPELINE_START_IO_READ=0
PIPELINE_START_IO_WRITE=0

# Función para obtener I/O del sistema
get_system_io() {
  local io_stats=$(cat /proc/diskstats | grep -E "sda|nvme0n1|vda" | head -1)
  if [[ -n "$io_stats" ]]; then
    local sectors_read=$(echo "$io_stats" | awk '{print $6}')
    local sectors_written=$(echo "$io_stats" | awk '{print $10}')
    local mb_read=$(echo "scale=2; $sectors_read * 512 / 1024 / 1024" | bc)
    local mb_written=$(echo "scale=2; $sectors_written * 512 / 1024 / 1024" | bc)
    echo "$mb_read|$mb_written"
  else
    echo "0|0"
  fi
}

# Función para iniciar monitoreo
start_monitoring() {
  local STEP_NAME=$1
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_METRICS="$METRICS_DIR/${STEP_NAME}_pidstat.csv"
  
  # Capturar I/O inicial
  local io_initial=$(get_system_io)
  IFS='|' read -r io_read_start io_write_start <<< "$io_initial"
  
  # Formato: PID, %usr, %system, %guest, %CPU, RSS, %MEM
  pidstat -h -r -u 2 > "$STEP_METRICS" 2>&1 &
  local PIDSTAT_PID=$!
  
  # Verificar que pidstat se inició
  sleep 1
  if ! kill -0 $PIDSTAT_PID 2>/dev/null; then
    echo "  ADVERTENCIA: pidstat no se inició" >&2
    PIDSTAT_PID=0
  fi
  
  # Iniciar iostat como respaldo
  local IOSTAT_PID=0
  if command -v iostat &> /dev/null; then
    iostat -x 2 > "$LOGS_DIR/${STEP_NAME}_iostat.log" 2>&1 &
    IOSTAT_PID=$!
  fi
  
  local START_TIME=$(date +%s)
  
  echo "$PIDSTAT_PID|$IOSTAT_PID|$START_TIME|$io_read_start|$io_write_start|$STEP_LOG|$STEP_TIME|$STEP_METRICS"
}

# Función para detener monitoreo
stop_monitoring() {
  local STEP_NAME=$1
  local MONITOR_INFO=$2
  local EXIT_CODE=$3
  
  IFS='|' read -r PIDSTAT_PID IOSTAT_PID START_TIME IO_READ_START IO_WRITE_START STEP_LOG STEP_TIME STEP_METRICS <<< "$MONITOR_INFO"
  
  # Detener procesos de monitoreo
  if [[ $PIDSTAT_PID -gt 0 ]]; then
    kill $PIDSTAT_PID 2>/dev/null || true
    wait $PIDSTAT_PID 2>/dev/null || true
  fi
  
  if [[ $IOSTAT_PID -gt 0 ]]; then
    kill $IOSTAT_PID 2>/dev/null || true
    wait $IOSTAT_PID 2>/dev/null || true
  fi
  
  # Calcular duración
  local END_TIME=$(date +%s)
  local DURATION=$((END_TIME - START_TIME))
  local DURATION_MIN=$(echo "scale=2; $DURATION / 60" | bc)
  
  # Capturar I/O final
  local io_final=$(get_system_io)
  IFS='|' read -r io_read_end io_write_end <<< "$io_final"
  
  local IO_READ_MB=$(echo "scale=2; $io_read_end - $IO_READ_START" | bc | awk '{printf "%.2f", $0}')
  local IO_WRITE_MB=$(echo "scale=2; $io_write_end - $IO_WRITE_START" | bc | awk '{printf "%.2f", $0}')
  local IO_TOTAL_MB=$(echo "scale=2; $IO_READ_MB + $IO_WRITE_MB" | bc | awk '{printf "%.2f", $0}')
  
  STEP_IO_READ["$STEP_NAME"]=$IO_READ_MB
  STEP_IO_WRITE["$STEP_NAME"]=$IO_WRITE_MB
  
  # Extraer métricas
  local MAX_MEM_KB="0"
  local MAX_MEM_MB="0"
  local MAX_MEM_GB="0"
  local CPU_PERCENT="0"
  
  if [[ -f "$STEP_TIME" ]]; then
    MAX_MEM_KB=$(grep "Maximum resident set size" "$STEP_TIME" 2>/dev/null | awk '{print $6}' || echo "0")
    MAX_MEM_MB=$(echo "scale=2; $MAX_MEM_KB / 1024" | bc | awk '{printf "%.2f", $0}')
    MAX_MEM_GB=$(echo "scale=3; $MAX_MEM_KB / 1024 / 1024" | bc | awk '{printf "%.3f", $0}')
    CPU_PERCENT=$(grep "Percent of CPU" "$STEP_TIME" 2>/dev/null | awk '{print $7}' | tr -d '%' || echo "0")
  fi
  
  # Guardar en CSV
  echo "$STEP_NAME,$(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S'),$(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S'),$DURATION,$DURATION_MIN,$MAX_MEM_KB,$MAX_MEM_MB,$MAX_MEM_GB,$CPU_PERCENT,$IO_READ_MB,$IO_WRITE_MB,$IO_TOTAL_MB,$EXIT_CODE" >> "$TIMING_LOG"
  
  # Mostrar resumen
  echo ""
  echo "  ╔════════════════════════════════════╗"
  echo "   MÉTRICAS: $STEP_NAME"
  echo "  ╚════════════════════════════════════╝"
  echo "   Duración:      ${DURATION}s (${DURATION_MIN} min)"
  echo "   Memoria máx:   ${MAX_MEM_MB} MB (${MAX_MEM_GB} GB)"
  echo "   CPU promedio:  ${CPU_PERCENT}%"
  echo "   I/O Lectura:   ${IO_READ_MB} MB"
  echo "   I/O Escritura: ${IO_WRITE_MB} MB"
  echo "   I/O Total:     ${IO_TOTAL_MB} MB"
  echo "   Estado:        $([ $EXIT_CODE -eq 0 ] && echo 'Exitoso' || echo "Error ($EXIT_CODE)")"
  echo "  ════════════════════════════════════"
  echo ""
}

# Función para ejecutar comando con monitoreo
run_monitored() {
  local STEP_NAME=$1
  shift
  local COMMAND="$@"
  
  echo ""
  echo "=========================================="
  echo "  Ejecutando: $STEP_NAME"
  echo "=========================================="
  echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
  
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"

  # Iniciar monitoreo
  local MONITOR_INFO=$(start_monitoring "$STEP_NAME")
  
  # Ejecutar comando con /usr/bin/time
  set +e
  /usr/bin/time -v bash -c "$COMMAND" > "$STEP_LOG" 2> "$STEP_TIME"
  local EXIT_CODE=$?
  set -e
  
  stop_monitoring "$STEP_NAME" "$MONITOR_INFO" "$EXIT_CODE"
  
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "ERROR: $STEP_NAME falló con código $EXIT_CODE"
    echo "Ver logs en: $STEP_LOG"
    return $EXIT_CODE
  fi
  
  echo "✓ $STEP_NAME completado exitosamente"
  return 0
}

# ============================================================================
# INICIO DEL PIPELINE
# ============================================================================

PIPELINE_START=$(date +%s)
PIPELINE_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  PIPELINE QIIME2 CON MONITOREO COMPLETO          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo "Hora de inicio: $PIPELINE_START_DATETIME"
echo ""
echo "Logs: $LOGS_DIR"
echo "Métricas: $METRICS_DIR"
echo ""

io_pipeline_start=$(get_system_io)
IFS='|' read -r PIPELINE_START_IO_READ PIPELINE_START_IO_WRITE <<< "$io_pipeline_start"

# ============================================================================
# VERIFICACIÓN
# ============================================================================

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio: $PROJECT_DIR"
  exit 1
fi

RAW_DIR="$PROJECT_DIR/raw_sequences"
if [[ ! -d "$RAW_DIR" ]]; then
  echo "ERROR: No existe raw_sequences: $RAW_DIR"
  exit 1
fi

# Detectar grupos
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

PREPROC_DIR="$PROJECT_DIR/preproc"
QIIME_DIR="$PROJECT_DIR/qiime2_results"
RESULTS_DIR="$PROJECT_DIR/results"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

mkdir -p "$PREPROC_DIR" "$QIIME_DIR" "$RESULTS_DIR"

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
# PASO 1: FASTP
# ============================================================================

for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_RAW="$RAW_DIR/$GRUPO"
  GRUPO_PREPROC="$PREPROC_DIR/$GRUPO"
  mkdir -p "$GRUPO_PREPROC"
  
  for fq1 in "$GRUPO_RAW"/*_1.fq.gz; do
    [[ ! -f "$fq1" ]] && continue
    
    fq2="${fq1/_1.fq.gz/_2.fq.gz}"
    [[ ! -f "$fq2" ]] && continue
    
    basename_fq=$(basename "$fq1" _1.fq.gz)
    out1="$GRUPO_PREPROC/${basename_fq}_filtered_1.fq.gz"
    out2="$GRUPO_PREPROC/${basename_fq}_filtered_2.fq.gz"
    html="$GRUPO_PREPROC/${basename_fq}_fastp.html"
    json="$GRUPO_PREPROC/${basename_fq}_fastp.json"
    
    FASTP_CMD="$FASTP_RUN \
      --in1 '$fq1' --in2 '$fq2' \
      --out1 '$out1' --out2 '$out2' \
      --html '$html' --json '$json' \
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

run_monitored "multiqc_fastp" "$MULTIQC_RUN '$PREPROC_DIR' -o '$PREPROC_DIR/multiqc_report' -n multiqc_fastp_report --force"

# ============================================================================
# PASO 2: DADA2
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
  
  echo "Importando datos para $GRUPO..."
  $CONDA_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --output-path "$DEMUX" \
    --input-format PairedEndFastqManifestPhred33V2
  
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

MERGE_TABLES_CMD="$CONDA_RUN qiime feature-table merge"
for GRUPO in "${GRUPOS[@]}"; do
  MERGE_TABLES_CMD="$MERGE_TABLES_CMD --i-tables $BASE_DADA2/$GRUPO/table.qza"
done
MERGE_TABLES_CMD="$MERGE_TABLES_CMD --o-merged-table $COMBINED_OUT/merged_table.qza"

run_monitored "merge_tables" "$MERGE_TABLES_CMD"

MERGE_SEQS_CMD="$CONDA_RUN qiime feature-table merge-seqs"
for GRUPO in "${GRUPOS[@]}"; do
  MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
done
MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"

run_monitored "merge_sequences" "$MERGE_SEQS_CMD"

PHYLO_COMBINED_CMD="$CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences '$COMBINED_OUT/merged_rep-seqs.qza' \
  --p-n-threads $PHYLO_THREADS \
  --o-alignment '$COMBINED_OUT/aligned-rep-seqs.qza' \
  --o-masked-alignment '$COMBINED_OUT/masked-aligned-rep-seqs.qza' \
  --o-tree '$COMBINED_OUT/unrooted-tree.qza' \
  --o-rooted-tree '$COMBINED_OUT/rooted-tree.qza' \
  --verbose"

run_monitored "phylogeny_combined" "$PHYLO_COMBINED_CMD"

CORE_METRICS_CMD="$CONDA_RUN qiime diversity core-metrics-phylogenetic \
  --i-table '$COMBINED_OUT/merged_table.qza' \
  --i-phylogeny '$COMBINED_OUT/rooted-tree.qza' \
  --m-metadata-file '$METADATA_FILE' \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir '$COMBINED_OUT/results' \
  --verbose"

run_monitored "core_metrics" "$CORE_METRICS_CMD"

# Análisis de significancia
echo ""
echo "Ejecutando análisis de significancia..."

for metric in shannon evenness faith_pd observed_features; do
  [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]] && \
    $CONDA_RUN qiime diversity alpha-group-significance \
      --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
done

for metric in unweighted_unifrac weighted_unifrac bray_curtis jaccard; do
  [[ -f "$COMBINED_OUT/results/${metric}_distance_matrix.qza" ]] && \
    $CONDA_RUN qiime diversity beta-group-significance \
      --i-distance-matrix "$COMBINED_OUT/results/${metric}_distance_matrix.qza" \
      --m-metadata-file "$METADATA_FILE" \
      --m-metadata-column Group \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv" \
      --p-pairwise
done

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
echo "Copiando visualizaciones..."
for GRUPO in "${GRUPOS[@]}"; do
  [[ -f "$BASE_DADA2/$GRUPO/denoising-stats.qzv" ]] && \
    cp "$BASE_DADA2/$GRUPO/denoising-stats.qzv" "$RESULTS_DIR/denoising-stats-${GRUPO}.qzv"
done
find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

# ============================================================================
# MÉTRICAS FINALES
# ============================================================================

PIPELINE_END=$(date +%s)
PIPELINE_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_DURATION=$((PIPELINE_END - PIPELINE_START))

io_pipeline_end=$(get_system_io)
IFS='|' read -r PIPELINE_END_IO_READ PIPELINE_END_IO_WRITE <<< "$io_pipeline_end"

PIPELINE_IO_READ=$(echo "scale=2; $PIPELINE_END_IO_READ - $PIPELINE_START_IO_READ" | bc | awk '{printf "%.2f", $0}')
PIPELINE_IO_WRITE=$(echo "scale=2; $PIPELINE_END_IO_WRITE - $PIPELINE_START_IO_WRITE" | bc | awk '{printf "%.2f", $0}')
PIPELINE_IO_TOTAL=$(echo "scale=2; $PIPELINE_IO_READ + $PIPELINE_IO_WRITE" | bc | awk '{printf "%.2f", $0}')

HOURS=$((TOTAL_DURATION / 3600))
MINUTES=$(((TOTAL_DURATION % 3600) / 60))
SECONDS=$((TOTAL_DURATION % 60))
TOTAL_MINUTES=$(echo "scale=2; $TOTAL_DURATION / 60" | bc)

TOTAL_MEMORY_MB=$(awk -F',' 'NR>1 {sum+=$7} END {printf "%.2f", sum}' "$TIMING_LOG")
AVG_CPU=$(awk -F',' 'NR>1 {sum+=$9; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}' "$TIMING_LOG")

# ============================================================================
# RESUMEN FINAL
# ============================================================================

cat > "$PIPELINE_SUMMARY" << EOF
╔══════════════════════════════════════════════════════════╗
║       RESUMEN COMPLETO DEL PIPELINE QIIME2               ║
╚══════════════════════════════════════════════════════════╝

INFORMACIÓN DEL PROYECTO
========================
Proyecto:              $PROJECT_NAME
Directorio:            $PROJECT_DIR
Grupos analizados:     ${GRUPOS[@]}

TIEMPOS DE EJECUCIÓN
====================
Inicio:                $PIPELINE_START_DATETIME
Fin:                   $PIPELINE_END_DATETIME
Duración total:        ${HOURS}h ${MINUTES}m ${SECONDS}s
Duración (minutos):    ${TOTAL_MINUTES} min

RECURSOS TOTALES
================
I/O Lectura total:     ${PIPELINE_IO_READ} MB
I/O Escritura total:   ${PIPELINE_IO_WRITE} MB
I/O Total:             ${PIPELINE_IO_TOTAL} MB
Memoria acumulada:     ${TOTAL_MEMORY_MB} MB
CPU promedio:          ${AVG_CPU}%

ARCHIVOS GENERADOS
==================
Logs:                  $LOGS_DIR
Métricas:              $METRICS_DIR
Visualizaciones:       $RESULTS_DIR
Resumen CSV:           $TIMING_LOG

PASOS EJECUTADOS
================
EOF

awk -F',' 'NR>1 {printf "%-30s %8.2f min  %10.2f MB  %6.1f%%  %8.2f MB I/O\n", $1, $5, $7, $9, $12}' "$TIMING_LOG" >> "$PIPELINE_SUMMARY"

cat >> "$PIPELINE_SUMMARY" << EOF

═══════════════════════════════════════════════════════════
Para visualizar gráficos detallados, ejecute:
  bash generate_plots.sh $PROJECT_NAME
═══════════════════════════════════════════════════════════
EOF

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          PIPELINE COMPLETADO EXITOSAMENTE            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
cat "$PIPELINE_SUMMARY"
echo ""
echo "SIGUIENTE PASO: Generar gráficos"
echo "  bash generate_plots.sh $PROJECT_NAME"
echo ""