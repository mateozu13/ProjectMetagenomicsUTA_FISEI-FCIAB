#!/usr/bin/env bash

set -euo pipefail

FASTP_TRIM_FRONT1=10
FASTP_TRIM_FRONT2=10
FASTP_CUT_TAIL=true
FASTP_QUALITY_PHRED=20
FASTP_LENGTH_REQUIRED=150
FASTP_THREADS=5
FASTP_DETECT_ADAPTERS=true

DADA2_TRIM_LEFT_F=0
DADA2_TRIM_LEFT_R=0
DADA2_TRUNC_LEN_F=0
DADA2_TRUNC_LEN_R=0
DADA2_MAX_EE_F=2.0
DADA2_MAX_EE_R=2.0
DADA2_THREADS=16

SAMPLING_DEPTH=6000
PHYLO_THREADS=5

export TMPDIR="/mnt/fast_tmp"
mkdir -p "$TMPDIR"

CONDA_RUN="/opt/conda/bin/conda run -n qiime2"
FASTP_RUN="/opt/conda/bin/conda run -n preproc fastp"
MULTIQC_RUN="/opt/conda/bin/conda run -n preproc multiqc"

if [[ $# -eq 2 ]] && [[ -f "$2" ]]; then
  echo "Cargando configuracion personalizada: $2"
  source "$2"
fi

if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto> [config_file]"
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

LOGS_DIR="$PROJECT_DIR/logs"
METRICS_DIR="$PROJECT_DIR/metrics"
mkdir -p "$LOGS_DIR"
mkdir -p "$METRICS_DIR"

MASTER_LOG="$LOGS_DIR/pipeline_master.log"
TIMING_LOG="$LOGS_DIR/timing_summary.csv"
SYSTEM_SUMMARY="$METRICS_DIR/system_summary.csv"
PIPELINE_SUMMARY="$METRICS_DIR/pipeline_summary.txt"

echo "step,start_time,end_time,duration_seconds,duration_minutes,max_memory_kb,max_memory_mb,max_memory_gb,cpu_percent,io_read_mb,io_write_mb,io_total_mb,exit_status" > "$TIMING_LOG"

echo "timestamp,step,cpu_user,cpu_system,cpu_idle,memory_used_mb,memory_free_mb,disk_read_mb,disk_write_mb" > "$SYSTEM_SUMMARY"

declare -A STEP_IO_READ
declare -A STEP_IO_WRITE
PIPELINE_START_IO_READ=0
PIPELINE_START_IO_WRITE=0

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
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"
  local STEP_METRICS="$METRICS_DIR/${STEP_NAME}_pidstat.csv"
  
  local io_initial=$(get_system_io)
  IFS='|' read -r io_read_start io_write_start <<< "$io_initial"
  
  pidstat -h -r -u 2 > "$STEP_METRICS" 2>&1 &
  local PIDSTAT_PID=$!
  
  sleep 1
  if ! kill -0 $PIDSTAT_PID 2>/dev/null; then
    echo "  ADVERTENCIA: pidstat no se inicio" >&2
    PIDSTAT_PID=0
  fi
  
  local IOSTAT_PID=0
  if command -v iostat &> /dev/null; then
    iostat -x 2 > "$LOGS_DIR/${STEP_NAME}_iostat.log" 2>&1 &
    IOSTAT_PID=$!
  fi
  
  local START_TIME=$(date +%s)
  
  echo "$PIDSTAT_PID|$IOSTAT_PID|$START_TIME|$io_read_start|$io_write_start|$STEP_LOG|$STEP_TIME|$STEP_METRICS"
}

stop_monitoring() {
  local STEP_NAME=$1
  local MONITOR_INFO=$2
  local EXIT_CODE=$3
  
  IFS='|' read -r PIDSTAT_PID IOSTAT_PID START_TIME IO_READ_START IO_WRITE_START STEP_LOG STEP_TIME STEP_METRICS <<< "$MONITOR_INFO"
  
  if [[ $PIDSTAT_PID -gt 0 ]]; then
    kill $PIDSTAT_PID 2>/dev/null || true
    wait $PIDSTAT_PID 2>/dev/null || true
  fi
  
  if [[ $IOSTAT_PID -gt 0 ]]; then
    kill $IOSTAT_PID 2>/dev/null || true
    wait $IOSTAT_PID 2>/dev/null || true
  fi
  
  local END_TIME=$(date +%s)
  local DURATION=$((END_TIME - START_TIME))
  local DURATION_MIN=$(echo "scale=2; $DURATION / 60" | bc)
  
  local io_final=$(get_system_io)
  IFS='|' read -r io_read_end io_write_end <<< "$io_final"
  
  local IO_READ_MB=$(echo "scale=2; $io_read_end - $IO_READ_START" | bc | awk '{printf "%.2f", $0}')
  local IO_WRITE_MB=$(echo "scale=2; $io_write_end - $IO_WRITE_START" | bc | awk '{printf "%.2f", $0}')
  local IO_TOTAL_MB=$(echo "scale=2; $IO_READ_MB + $IO_WRITE_MB" | bc | awk '{printf "%.2f", $0}')
  
  STEP_IO_READ["$STEP_NAME"]=$IO_READ_MB
  STEP_IO_WRITE["$STEP_NAME"]=$IO_WRITE_MB
  
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
  echo "  METRICAS: $STEP_NAME"
  echo "  Duracion:      ${DURATION}s (${DURATION_MIN} min)"
  echo "  Memoria max:   ${MAX_MEM_MB} MB (${MAX_MEM_GB} GB)"
  echo "  CPU promedio:  ${CPU_PERCENT}%"
  echo "  I/O Lectura:   ${IO_READ_MB} MB"
  echo "  I/O Escritura: ${IO_WRITE_MB} MB"
  echo "  I/O Total:     ${IO_TOTAL_MB} MB"
  echo "  Estado:        $([ $EXIT_CODE -eq 0 ] && echo 'Exitoso' || echo "Error ($EXIT_CODE)")"
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
  
  local STEP_LOG="$LOGS_DIR/${STEP_NAME}.log"
  local STEP_TIME="$LOGS_DIR/${STEP_NAME}_time.log"

  local MONITOR_INFO=$(start_monitoring "$STEP_NAME")
  
  set +e
  /usr/bin/time -v bash -c "$COMMAND" > "$STEP_LOG" 2> "$STEP_TIME"
  local EXIT_CODE=$?
  set -e
  
  stop_monitoring "$STEP_NAME" "$MONITOR_INFO" "$EXIT_CODE"
  
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "ERROR: $STEP_NAME fallo con codigo $EXIT_CODE"
    echo "Ver logs en: $STEP_LOG"
    return $EXIT_CODE
  fi
  
  echo "COMPLETADO: $STEP_NAME completado exitosamente"
  return 0
}

PIPELINE_START=$(date +%s)
PIPELINE_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

io_pipeline_start=$(get_system_io)
IFS='|' read -r PIPELINE_START_IO_READ PIPELINE_START_IO_WRITE <<< "$io_pipeline_start"

echo ""
echo "=========================================="
echo "  PIPELINE OPTIMIZADO CON MONITOREO COMPLETO"
echo "=========================================="
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo "Hora de inicio: $PIPELINE_START_DATETIME"
echo ""
echo "Logs: $LOGS_DIR"
echo "Metricas: $METRICS_DIR"
echo ""
echo "OPTIMIZACIONES ACTIVAS:"
echo "----------------------"
echo "- GNU Parallel para procesamiento simultaneo"
echo "- pigz para compresion/descompresion paralela"
echo "- tmpfs para archivos temporales"
echo "- Monitoreo detallado de recursos"
echo ""
echo "PARAMETROS DADA2:"
echo "  trunc_len_f: $DADA2_TRUNC_LEN_F (0 = sin truncamiento)"
echo "  trunc_len_r: $DADA2_TRUNC_LEN_R (0 = sin truncamiento)"
echo ""

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

RAW_DIR="$PROJECT_DIR/raw_sequences"
PREPROC_DIR="$PROJECT_DIR/preproc"
QIIME_DIR="$PROJECT_DIR/qiime2_results"
RESULTS_DIR="$PROJECT_DIR/results"
METADATA_FILE="$PROJECT_DIR/metadata.tsv"

mkdir -p "$PREPROC_DIR"
mkdir -p "$QIIME_DIR"
mkdir -p "$RESULTS_DIR"

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

# FUNCION CORREGIDA: Usa fastp de forma directa con pigz solo para descompresion
process_fastp_sample() {
    local grupo=$1
    local r1_file=$2
    local sample_id=$(basename "$r1_file" | sed 's/_1\.fq\.gz$//')
    local r2_file="${r1_file/_1.fq.gz/_2.fq.gz}"
    
    local out_dir="$PREPROC_DIR/$grupo"
    mkdir -p "$out_dir"
    
    local out_r1="$out_dir/${sample_id}_filtered_1.fq.gz"
    local out_r2="$out_dir/${sample_id}_filtered_2.fq.gz"
    local json_report="$out_dir/${sample_id}_fastp.json"
    local html_report="$out_dir/${sample_id}_fastp.html"
    
    echo "  Procesando: $sample_id ($grupo)" >&2
    
    # SOLUCION: Usar fastp directamente (no stdin) y comprimir salida con pigz
    $FASTP_RUN \
        -i "$r1_file" \
        -I "$r2_file" \
        --stdout \
        --cut_tail \
        --trim_front1 $FASTP_TRIM_FRONT1 \
        --trim_front2 $FASTP_TRIM_FRONT2 \
        --qualified_quality_phred $FASTP_QUALITY_PHRED \
        --length_required $FASTP_LENGTH_REQUIRED \
        --thread $FASTP_THREADS \
        --detect_adapter_for_pe \
        --json "$json_report" \
        --html "$html_report" 2>/dev/null | \
    pigz -p 4 > "$out_dir/${sample_id}_filtered_interleaved.fq.gz"
    
    # Separar interleaved en R1 y R2 usando pigz
    pigz -dc "$out_dir/${sample_id}_filtered_interleaved.fq.gz" | \
    awk 'NR%8<5' | pigz -p 2 > "$out_r1" &
    
    pigz -dc "$out_dir/${sample_id}_filtered_interleaved.fq.gz" | \
    awk 'NR%8>=5' | pigz -p 2 > "$out_r2" &
    
    wait
    rm "$out_dir/${sample_id}_filtered_interleaved.fq.gz"
}

export -f process_fastp_sample
export PREPROC_DIR FASTP_RUN FASTP_THREADS FASTP_TRIM_FRONT1 FASTP_TRIM_FRONT2
export FASTP_QUALITY_PHRED FASTP_LENGTH_REQUIRED

echo "=========================================="
echo "PASO 1: Preprocesamiento PARALELO con fastp"
echo "=========================================="
echo ""

FASTP_CMD="find '$RAW_DIR' -name '*_1.fq.gz' | \
    parallel -j 3 --will-cite --eta \
    'grupo=\$(basename \$(dirname {})); process_fastp_sample \"\$grupo\" {}'"

run_monitored "fastp_parallel" "$FASTP_CMD"

MULTIQC_CMD="$MULTIQC_RUN '$PREPROC_DIR' -o '$PREPROC_DIR/multiqc_report' -n multiqc_fastp_report --force"
run_monitored "multiqc_fastp" "$MULTIQC_CMD"

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

echo ""
echo "=========================================="
echo "PASO 2: DADA2 denoising"
echo "=========================================="
echo ""

for GRUPO in "${GRUPOS[@]}"; do
  echo "Procesando grupo: $GRUPO"
  
  GRUPO_OUT="$BASE_DADA2/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  MANIFEST="$GRUPO_OUT/manifest.tsv"
  echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > "$MANIFEST"
  
  for r1 in "$PREPROC_DIR/$GRUPO"/*_filtered_1.fq.gz; do
    if [[ -f "$r1" ]]; then
      sample=$(basename "$r1" | sed 's/_filtered_1\.fq\.gz$//')
      r2="${r1/_1.fq.gz/_2.fq.gz}"
      echo -e "$sample\t$r1\t$r2" >> "$MANIFEST"
    fi
  done
  
  IMPORT_CMD="$CONDA_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path '$MANIFEST' \
    --input-format PairedEndFastqManifestPhred33V2 \
    --output-path '$GRUPO_OUT/paired-end-demux.qza'"
  
  run_monitored "import_${GRUPO}" "$IMPORT_CMD"
  
  DADA2_CMD="$CONDA_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs '$GRUPO_OUT/paired-end-demux.qza' \
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

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

echo ""
echo "=========================================="
echo "PASO 3: Arboles filogeneticos PARALELOS"
echo "=========================================="
echo ""

build_phylogeny() {
    local grupo=$1
    local grupo_out="$BASE_PHYLO/$grupo"
    mkdir -p "$grupo_out"
    
    echo "  Construyendo arbol para: $grupo" >&2
    
    $CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
        --i-sequences "$BASE_DADA2/$grupo/rep-seqs.qza" \
        --p-n-threads $PHYLO_THREADS \
        --o-alignment "$grupo_out/aligned-rep-seqs.qza" \
        --o-masked-alignment "$grupo_out/masked-aligned-rep-seqs.qza" \
        --o-tree "$grupo_out/unrooted-tree.qza" \
        --o-rooted-tree "$grupo_out/rooted-tree.qza" \
        --verbose 2>&1
}

export -f build_phylogeny
export BASE_PHYLO BASE_DADA2 CONDA_RUN PHYLO_THREADS

PHYLO_CMD="echo '${GRUPOS[@]}' | tr ' ' '\n' | parallel -j 3 --will-cite 'build_phylogeny {}'"
run_monitored "phylogeny_parallel" "$PHYLO_CMD"

echo ""
echo "=========================================="
echo "PASO 4: Analisis de diversidad comparativo"
echo "=========================================="
echo ""

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
  --p-n-threads 12 \
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

echo ""
echo "Ejecutando analisis de significancia..."

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

echo ""
echo "=========================================="
echo "PASO 5: Copiando visualizaciones"
echo "=========================================="

for GRUPO in "${GRUPOS[@]}"; do
  [[ -f "$BASE_DADA2/$GRUPO/denoising-stats.qzv" ]] && \
    cp "$BASE_DADA2/$GRUPO/denoising-stats.qzv" "$RESULTS_DIR/denoising-stats-${GRUPO}.qzv"
done

find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

NUM_QZV=$(ls -1 "$RESULTS_DIR"/*.qzv 2>/dev/null | wc -l)
echo "  COMPLETADO: $NUM_QZV visualizaciones copiadas"
echo ""

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

cat > "$PIPELINE_SUMMARY" << EOF
========================================
  RESUMEN COMPLETO DEL PIPELINE OPTIMIZADO
========================================

INFORMACION DEL PROYECTO
========================
Proyecto:              $PROJECT_NAME
Directorio:            $PROJECT_DIR
Grupos analizados:     ${GRUPOS[@]}

TIEMPOS DE EJECUCION
====================
Inicio:                $PIPELINE_START_DATETIME
Fin:                   $PIPELINE_END_DATETIME
Duracion total:        ${HOURS}h ${MINUTES}m ${SECONDS}s
Duracion (minutos):    ${TOTAL_MINUTES} min

RECURSOS TOTALES
================
I/O Lectura total:     ${PIPELINE_IO_READ} MB
I/O Escritura total:   ${PIPELINE_IO_WRITE} MB
I/O Total:             ${PIPELINE_IO_TOTAL} MB
Memoria acumulada:     ${TOTAL_MEMORY_MB} MB
CPU promedio:          ${AVG_CPU}%

OPTIMIZACIONES APLICADAS
=========================
- Procesamiento paralelo con GNU Parallel (3 jobs simultaneos)
- Compresion/descompresion paralela con pigz
- Construccion paralela de arboles filogeneticos
- Uso de tmpfs para archivos temporales
- Monitoreo detallado de recursos por etapa
- DADA2 sin truncamiento (fastp ya proceso las secuencias)

ARCHIVOS GENERADOS
==================
Logs:                  $LOGS_DIR
Metricas:              $METRICS_DIR
Visualizaciones:       $RESULTS_DIR
Resumen CSV:           $TIMING_LOG

PASOS EJECUTADOS
================
EOF

awk -F',' 'NR>1 {printf "%-30s %8.2f min  %10.2f MB  %6.1f%%  %8.2f MB I/O\n", $1, $5, $7, $9, $12}' "$TIMING_LOG" >> "$PIPELINE_SUMMARY"

cat >> "$PIPELINE_SUMMARY" << EOF

========================================
Para visualizar graficos detallados, ejecute:
  bash generate_plots.sh $PROJECT_NAME
========================================
EOF

echo ""
echo "=========================================="
echo "  PIPELINE OPTIMIZADO COMPLETADO EXITOSAMENTE"
echo "=========================================="
echo ""
cat "$PIPELINE_SUMMARY"
echo ""
echo "SIGUIENTE PASO: Generar graficos"
echo "  bash generate_plots.sh $PROJECT_NAME"
echo ""