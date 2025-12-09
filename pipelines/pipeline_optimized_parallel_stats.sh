#!/usr/bin/env bash
################################################################################
# Pipeline optimizado de análisis metagenómico con monitoreo completo
# Incluye: Preprocesamiento paralelo, DADA2, filogenia, diversidad
# Métricas: CPU, Memoria, I/O de disco, Tiempo total y por paso
# 
# Uso: bash pipeline_optimized_parallel_stats.sh <nombre_proyecto> [config_file]
# Ejemplo: bash pipeline_optimized_parallel_stats.sh Proyecto_Optimizado
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURACIÓN DE PARÁMETROS
# ============================================================================

FASTP_TRIM_FRONT1=10
FASTP_TRIM_FRONT2=10
FASTP_CUT_TAIL=true
FASTP_QUALITY_PHRED=20
FASTP_LENGTH_REQUIRED=150
FASTP_THREADS=5
FASTP_DETECT_ADAPTERS=true

DADA2_TRIM_LEFT_F=0
DADA2_TRIM_LEFT_R=0
DADA2_TRUNC_LEN_F=230
DADA2_TRUNC_LEN_R=220
DADA2_MAX_EE_F=2.0
DADA2_MAX_EE_R=2.0
DADA2_THREADS=16

SAMPLING_DEPTH=6000
PHYLO_THREADS=5

export TMPDIR="/mnt/fast_tmp"
mkdir -p "$TMPDIR"

CONDA_QIIME2_RUN="/opt/conda/bin/conda run -n qiime2"

if [[ -f "/opt/conda/envs/preproc/bin/fastp" ]]; then
    FASTP_BIN="/opt/conda/envs/preproc/bin/fastp"
elif [[ -f "/usr/local/bin/fastp" ]]; then
    FASTP_BIN="/usr/local/bin/fastp"
else
    FASTP_BIN="fastp"
fi

if [[ -f "/opt/conda/envs/preproc/bin/multiqc" ]]; then
    MULTIQC_BIN="/opt/conda/envs/preproc/bin/multiqc"
else
    MULTIQC_BIN="multiqc"
fi

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

TIMING_LOG="$LOGS_DIR/timing_summary.csv"
SYSTEM_SUMMARY="$METRICS_DIR/system_summary.csv"
PIPELINE_SUMMARY="$METRICS_DIR/pipeline_summary.txt"

echo "step,start_time,end_time,duration_seconds,duration_minutes,max_memory_kb,max_memory_mb,max_memory_gb,cpu_percent,io_read_mb,io_write_mb,io_total_mb,exit_status" > "$TIMING_LOG"
echo "timestamp,step,cpu_user,cpu_system,cpu_idle,memory_used_mb,memory_free_mb,disk_read_mb,disk_write_mb" > "$SYSTEM_SUMMARY"

declare -A STEP_IO_READ
declare -A STEP_IO_WRITE

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

start_monitoring() {
  local STEP_NAME=$1
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_METRICS="$METRICS_DIR/${STEP_NAME}_pidstat.csv"
  
  local io_initial=$(get_system_io)
  IFS='|' read -r io_read_start io_write_start <<< "$io_initial"
  
  pidstat -h -r -u 2 > "$STEP_METRICS" 2>&1 &
  local PIDSTAT_PID=$!
  sleep 1
  
  local IOSTAT_PID=0
  if command -v iostat &> /dev/null; then
    iostat -x 2 > "$LOGS_DIR/${STEP_NAME}_iostat.log" 2>&1 &
    IOSTAT_PID=$!
  fi
  
  local START_TIME=$(date +%s)
  echo "$PIDSTAT_PID|$IOSTAT_PID|$START_TIME|$io_read_start|$io_write_start|$STEP_LOG|$STEP_METRICS"
}

stop_monitoring() {
  local STEP_NAME=$1
  local MONITOR_INFO=$2
  local EXIT_CODE=$3
  
  IFS='|' read -r PIDSTAT_PID IOSTAT_PID START_TIME IO_READ_START IO_WRITE_START STEP_LOG STEP_METRICS <<< "$MONITOR_INFO"
  local STEP_TIME="$STEP_LOG"
  
  [[ $PIDSTAT_PID -gt 0 ]] && kill $PIDSTAT_PID 2>/dev/null || true
  [[ $IOSTAT_PID -gt 0 ]] && kill $IOSTAT_PID 2>/dev/null || true
  
  local END_TIME=$(date +%s)
  local DURATION=$((END_TIME - START_TIME))
  local DURATION_MIN=$(echo "scale=2; $DURATION / 60" | bc)
  
  local io_final=$(get_system_io)
  IFS='|' read -r io_read_end io_write_end <<< "$io_final"
  
  local IO_READ_MB=$(echo "scale=2; $io_read_end - $IO_READ_START" | bc | awk '{printf "%.2f", $0}')
  local IO_WRITE_MB=$(echo "scale=2; $io_write_end - $IO_WRITE_START" | bc | awk '{printf "%.2f", $0}')
  local IO_TOTAL_MB=$(echo "scale=2; $IO_READ_MB + $IO_WRITE_MB" | bc | awk '{printf "%.2f", $0}')
  
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
  
  echo "$STEP_NAME,$(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S'),$(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S'),$DURATION,$DURATION_MIN,$MAX_MEM_KB,$MAX_MEM_MB,$MAX_MEM_GB,$CPU_PERCENT,$IO_READ_MB,$IO_WRITE_MB,$IO_TOTAL_MB,$EXIT_CODE" >> "$TIMING_LOG"
  
  echo ""
  echo "  ╔═══════════════════════════════════════╗"
  echo "   MÉTRICAS: $STEP_NAME"
  echo "  ╚═══════════════════════════════════════╝"
  echo "   Duración:      ${DURATION}s (${DURATION_MIN} min)"
  echo "   Memoria máx:   ${MAX_MEM_MB} MB (${MAX_MEM_GB} GB)"
  echo "   CPU promedio:  ${CPU_PERCENT}%"
  echo "   I/O Lectura:   ${IO_READ_MB} MB"
  echo "   I/O Escritura: ${IO_WRITE_MB} MB"
  echo "   I/O Total:     ${IO_TOTAL_MB} MB"
  echo "   Estado:        $([ $EXIT_CODE -eq 0 ] && echo 'Exitoso' || echo "Error ($EXIT_CODE)")"
  echo "  ═══════════════════════════════════════"
  echo ""
}

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
  local MONITOR_INFO=$(start_monitoring "$STEP_NAME")
  
  set +e
  /usr/bin/time -v bash -c "$COMMAND" > "$STEP_LOG" 2> "$STEP_LOG"
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

io_pipeline_start=$(get_system_io)
IFS='|' read -r PIPELINE_START_IO_READ PIPELINE_START_IO_WRITE <<< "$io_pipeline_start"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  PIPELINE OPTIMIZADO CON MONITOREO COMPLETO  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo "Hora de inicio: $PIPELINE_START_DATETIME"
echo ""
echo "Logs: $LOGS_DIR"
echo "Métricas: $METRICS_DIR"
echo ""
echo "OPTIMIZACIONES ACTIVAS:"
echo "----------------------"
echo "✓ GNU Parallel para procesamiento simultáneo"
echo "✓ tmpfs para archivos temporales"
echo "✓ Monitoreo detallado de recursos"
echo ""

# ============================================================================
# VERIFICACIÓN
# ============================================================================

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio: $PROJECT_DIR"
  exit 1
fi

RAW_DIR="$PROJECT_DIR/raw_sequences"
QIIME_DIR="$PROJECT_DIR/qiime2_analysis"
RESULTS_DIR="$PROJECT_DIR/results"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

mkdir -p "$QIIME_DIR"
mkdir -p "$RESULTS_DIR"

GRUPOS=($(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort))
echo "Grupos detectados: ${GRUPOS[@]}"
echo ""

echo ""
echo "=========================================="
echo "PASO 1: Control de calidad con fastp"
echo "=========================================="
echo ""
QC_DIR="$PROJECT_DIR/qc_reports"
CLEAN_DIR="$PROJECT_DIR/cleaned_sequences"
mkdir -p "$QC_DIR"
mkdir -p "$CLEAN_DIR"

process_fastp_sample() {
  local fq1=$1
  local fq2=$2
  local sample_id=$3
  local grupo=$4
  
  if [[ -z "$sample_id" || "$sample_id" == "/" ]]; then
     echo "ERROR: ID de muestra inválido." >&2; exit 1
  fi
    
  local out_dir="$CLEAN_DIR/$grupo"
  mkdir -p "$out_dir"
    
  local out1="$out_dir/${sample_id}_1.fq.gz"
  local out2="$out_dir/${sample_id}_2.fq.gz"
  local json="$QC_DIR/${sample_id}_fastp.json"
  local html="$QC_DIR/${sample_id}_fastp.html"

  "$FASTP_BIN" \
    -i "$fq1" -I "$fq2" \
    -o "$out1" -O "$out2" \
    --trim_front1 $FASTP_TRIM_FRONT1 --trim_front2 $FASTP_TRIM_FRONT2 \
    $([ "$FASTP_CUT_TAIL" = true ] && echo "--cut_tail") \
    --qualified_quality_phred $FASTP_QUALITY_PHRED \
    --length_required $FASTP_LENGTH_REQUIRED \
    --thread $FASTP_THREADS \
    $([ "$FASTP_DETECT_ADAPTERS" = true ] && echo "--detect_adapter_for_pe") \
    --json "$json" \
    --html "$html" 2>/dev/null
}

export -f process_fastp_sample
export CLEAN_DIR QC_DIR FASTP_BIN FASTP_TRIM_FRONT1 FASTP_TRIM_FRONT2 FASTP_CUT_TAIL FASTP_QUALITY_PHRED FASTP_LENGTH_REQUIRED FASTP_THREADS FASTP_DETECT_ADAPTERS

FASTP_CMD=$(cat << 'EOF'
find "$RAW_DIR" -name "*_1.fq.gz" | while read fq1; do
    fq2="${fq1/_1.fq.gz/_2.fq.gz}"
    grupo=$(basename $(dirname "$fq1"))
    sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
    if [[ -f "$fq2" ]]; then
        printf "%s\t%s\t%s\t%s\n" "$fq1" "$fq2" "$sample_id" "$grupo"
    fi
done | parallel -j 3 --colsep '\t' --will-cite 'process_fastp_sample {1} {2} {3} {4}'
EOF
)

export RAW_DIR
run_monitored "1_Control_Calidad" "$FASTP_CMD"

echo ""
echo "=========================================="
echo "PASO 2: REPORTE MULTIQC"
echo "=========================================="
echo ""

MULTIQC_CMD="$MULTIQC_BIN '$QC_DIR' -o '$QC_DIR' -n multiqc_report.html --force 2>/dev/null"
run_monitored "2_Reporte_MultiQC" "$MULTIQC_CMD"


echo ""
echo "=========================================="
echo "PASO 3: DADA2 (Denoising)"
echo "=========================================="
echo ""
BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"
ALL_SAMPLES_OUT="$BASE_DADA2/todas_muestras"
mkdir -p "$ALL_SAMPLES_OUT"

MANIFEST="$ALL_SAMPLES_OUT/manifest.tsv"
printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST"

COUNT=0
for GRUPO in "${GRUPOS[@]}"; do
 echo ""
  echo "Procesando grupo: $GRUPO"
  echo "----------------------------------------"
  for r1 in "$CLEAN_DIR/$GRUPO"/*_1.fq.gz; do
    if [[ -f "$r1" ]]; then
        sample=$(basename "$r1" | sed 's/_1\.fq\.gz$//')
        r2="${r1/_1.fq.gz/_2.fq.gz}"
        printf "%s\t%s\t%s\n" "$sample" "$r1" "$r2" >> "$MANIFEST"
        COUNT=$((COUNT+1))
    fi
  done
done

if [[ "$COUNT" -eq 0 ]]; then
   echo "ERROR: No se encontraron archivos procesados."
   exit 1
fi

echo "Total de muestras a procesar: $COUNT"

IMPORT_CMD="$CONDA_QIIME2_RUN qiime tools import --type 'SampleData[PairedEndSequencesWithQuality]' --input-path '$MANIFEST' --input-format PairedEndFastqManifestPhred33V2 --output-path '$ALL_SAMPLES_OUT/demux.qza'"

run_monitored "3_Importar_QIIME2" "$IMPORT_CMD"

# ============================================================================
# DADA2 DENOISING (TODAS LAS MUESTRAS JUNTAS)
# ============================================================================

DADA2_CMD="$CONDA_QIIME2_RUN qiime dada2 denoise-paired --i-demultiplexed-seqs '$ALL_SAMPLES_OUT/demux.qza' --p-trim-left-f $DADA2_TRIM_LEFT_F --p-trim-left-r $DADA2_TRIM_LEFT_R --p-trunc-len-f $DADA2_TRUNC_LEN_F --p-trunc-len-r $DADA2_TRUNC_LEN_R --p-max-ee-f $DADA2_MAX_EE_F --p-max-ee-r $DADA2_MAX_EE_R --p-n-threads $DADA2_THREADS --o-table '$ALL_SAMPLES_OUT/table.qza' --o-representative-sequences '$ALL_SAMPLES_OUT/rep-seqs.qza' --o-denoising-stats '$ALL_SAMPLES_OUT/denoising-stats.qza' --verbose"

run_monitored "4_DADA2_Denoising" "$DADA2_CMD"

EXPORT_STATS_CMD="$CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file '$ALL_SAMPLES_OUT/denoising-stats.qza' --o-visualization '$RESULTS_DIR/denoising-stats-final.qzv'"

run_monitored "5_Exportar_Stats" "$EXPORT_STATS_CMD"

echo ""
echo "=========================================="
echo "PASO 4: Árboles filogenéticos"
echo "=========================================="
echo ""

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

PHYLO_CMD="$CONDA_QIIME2_RUN qiime phylogeny align-to-tree-mafft-fasttree --i-sequences '$ALL_SAMPLES_OUT/rep-seqs.qza' --p-n-threads $PHYLO_THREADS --o-alignment '$BASE_PHYLO/aligned-rep-seqs.qza' --o-masked-alignment '$BASE_PHYLO/masked-aligned-rep-seqs.qza' --o-tree '$BASE_PHYLO/unrooted-tree.qza' --o-rooted-tree '$BASE_PHYLO/rooted-tree.qza' --verbose"

run_monitored "6_Arbol_Filogenetico" "$PHYLO_CMD"

echo ""
echo "=========================================="
echo "PASO 5: Diversidad y Análisis final"
echo "=========================================="
echo ""

OUT_DIV="$QIIME_DIR/core_diversity"
mkdir -p "$OUT_DIV"

CORE_METRICS_CMD="$CONDA_QIIME2_RUN qiime diversity core-metrics-phylogenetic --i-table '$ALL_SAMPLES_OUT/table.qza' --i-phylogeny '$BASE_PHYLO/rooted-tree.qza' --m-metadata-file '$METADATA_FILE' --p-sampling-depth $SAMPLING_DEPTH --output-dir '$OUT_DIV' --verbose"

run_monitored "7_Diversidad_Core" "$CORE_METRICS_CMD"

# ============================================================================
# VISUALIZACIONES GRUPALES
# ============================================================================

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$OUT_DIV/${metric}_vector.qza" ]]; then
    ALPHA_SIG_CMD="$CONDA_QIIME2_RUN qiime diversity alpha-group-significance --i-alpha-diversity '$OUT_DIV/${metric}_vector.qza' --m-metadata-file '$METADATA_FILE' --o-visualization '$RESULTS_DIR/${metric}-group-significance.qzv'"
    run_monitored "8_Alpha_Sig_${metric}" "$ALPHA_SIG_CMD"
  fi
done

RAREFACTION_CMD="$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction --i-table '$ALL_SAMPLES_OUT/table.qza' --i-phylogeny '$BASE_PHYLO/rooted-tree.qza' --m-metadata-file '$METADATA_FILE' --p-max-depth $SAMPLING_DEPTH --p-steps 20 --o-visualization '$RESULTS_DIR/alpha-rarefaction.qzv'"

run_monitored "9_Alpha_Rarefaction" "$RAREFACTION_CMD"

# ============================================================================
# VISUALIZACIONES INDIVIDUALES
# ============================================================================

METADATA_INDIVIDUAL="$PROJECT_DIR/metadata_individual_samples.tsv"
ID_COL_NAME=$(head -n 1 "$METADATA_FILE" | cut -f1)
awk -F'\t' 'BEGIN {OFS="\t"} 
    NR==1 {print $0, "Muestra_Unica"} 
    NR==2 {print $0, "categorical"} 
    NR>2 {print $0, $1}' "$METADATA_FILE" > "$METADATA_INDIVIDUAL"

RAREFACTION_IND_CMD="$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction --i-table '$ALL_SAMPLES_OUT/table.qza' --i-phylogeny '$BASE_PHYLO/rooted-tree.qza' --m-metadata-file '$METADATA_INDIVIDUAL' --p-max-depth $SAMPLING_DEPTH --p-steps 20 --o-visualization '$RESULTS_DIR/alpha-rarefaction-individual.qzv'"

run_monitored "10_Rarefaction_Individual" "$RAREFACTION_IND_CMD"

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$OUT_DIV/${metric}_vector.qza" ]]; then
    ALPHA_IND_CMD="$CONDA_QIIME2_RUN qiime diversity alpha-group-significance --i-alpha-diversity '$OUT_DIV/${metric}_vector.qza' --m-metadata-file '$METADATA_INDIVIDUAL' --o-visualization '$RESULTS_DIR/${metric}-individual.qzv'"
    run_monitored "11_Alpha_Ind_${metric}" "$ALPHA_IND_CMD"
  fi
done

for pcoa in "$OUT_DIV/"*_pcoa_results.qza; do
    if [[ -f "$pcoa" ]]; then
        BASE_NAME=$(basename "$pcoa" _pcoa_results.qza)
        BETA_IND_CMD="$CONDA_QIIME2_RUN qiime emperor plot --i-pcoa '$pcoa' --m-metadata-file '$METADATA_INDIVIDUAL' --o-visualization '$RESULTS_DIR/${BASE_NAME}_emperor_individual.qzv'"
        run_monitored "12_Beta_Ind_${BASE_NAME}" "$BETA_IND_CMD" || true
    fi
done

# ============================================================================
# TABLAS MAESTRAS
# ============================================================================

CMD_ALPHA_MASTER="$CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file '$METADATA_FILE'"
for f in "$OUT_DIV/"*_vector.qza; do
    if [[ -f "$f" ]]; then
        CMD_ALPHA_MASTER="$CMD_ALPHA_MASTER --m-input-file '$f'"
    fi
done
CMD_ALPHA_MASTER="$CMD_ALPHA_MASTER --o-visualization '$RESULTS_DIR/TABLA_FINAL_ALPHA_MUESTRAS.qzv'"

run_monitored "13_Tabla_Alpha_Samples" "$CMD_ALPHA_MASTER"

for f in "$OUT_DIV/"*_pcoa_results.qza; do
    if [[ -f "$f" ]]; then
        BASE_NAME=$(basename "$f" .qza)
        CMD_BETA="$CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file '$METADATA_FILE' --m-input-file '$f' --o-visualization '$RESULTS_DIR/TABLA_COORDENADAS_${BASE_NAME}.qzv'"
        run_monitored "14_Tabla_Coords_${BASE_NAME}" "$CMD_BETA" || true
    fi
done

find "$OUT_DIV" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

# ============================================================================
# RESUMEN FINAL
# ============================================================================

PIPELINE_END=$(date +%s)
PIPELINE_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
PIPELINE_DURATION=$((PIPELINE_END - PIPELINE_START))
PIPELINE_DURATION_MIN=$(echo "scale=2; $PIPELINE_DURATION / 60" | bc)

io_pipeline_end=$(get_system_io)
IFS='|' read -r PIPELINE_END_IO_READ PIPELINE_END_IO_WRITE <<< "$io_pipeline_end"

TOTAL_IO_READ=$(echo "scale=2; $PIPELINE_END_IO_READ - $PIPELINE_START_IO_READ" | bc | awk '{printf "%.2f", $0}')
TOTAL_IO_WRITE=$(echo "scale=2; $PIPELINE_END_IO_WRITE - $PIPELINE_START_IO_WRITE" | bc | awk '{printf "%.2f", $0}')
TOTAL_IO=$(echo "scale=2; $TOTAL_IO_READ + $TOTAL_IO_WRITE" | bc | awk '{printf "%.2f", $0}')

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           PIPELINE COMPLETADO                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Inicio:          $PIPELINE_START_DATETIME"
echo "Fin:             $PIPELINE_END_DATETIME"
echo "Duración total:  ${PIPELINE_DURATION}s (${PIPELINE_DURATION_MIN} min)"
echo ""
echo "I/O Total Lectura:   ${TOTAL_IO_READ} MB"
echo "I/O Total Escritura: ${TOTAL_IO_WRITE} MB"
echo "I/O Total:           ${TOTAL_IO} MB"
echo ""
echo "Resultados disponibles en:"
echo "  - Resultados generales:  $RESULTS_DIR"
echo "  - Logs:                  $LOGS_DIR"
echo "  - Métricas:              $METRICS_DIR"
echo ""
echo "Archivos de interés:"
echo "  1. Tabla Alpha (todas las métricas): TABLA_FINAL_ALPHA_MUESTRAS.qzv"
echo "  2. Visualizaciones individuales:     *-individual.qzv"
echo "  3. Estadísticas denoising:           denoising-stats-final.qzv"
echo ""
echo "═══════════════════════════════════════════════"
echo ""
echo "SIGUIENTE PASO: Generar gráficos"
echo "  bash generate_plots.sh $PROJECT_NAME"
echo ""