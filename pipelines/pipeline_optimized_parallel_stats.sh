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

export FASTP_TRIM_FRONT1=10
export FASTP_TRIM_FRONT2=10
export FASTP_CUT_TAIL=true
export FASTP_QUALITY_PHRED=20
export FASTP_LENGTH_REQUIRED=150
export FASTP_THREADS=5
export FASTP_DETECT_ADAPTERS=true

export DADA2_TRIM_LEFT_F=0
export DADA2_TRIM_LEFT_R=0
export DADA2_TRUNC_LEN_F=230
export DADA2_TRUNC_LEN_R=220
export DADA2_MAX_EE_F=2.0
export DADA2_MAX_EE_R=2.0
export DADA2_THREADS=16

export SAMPLING_DEPTH=6000
export PHYLO_THREADS=5

export TMPDIR="/mnt/fast_tmp"
mkdir -p "$TMPDIR"

# Configuración de entornos y ejecutables
export CONDA_QIIME2_RUN="/opt/conda/bin/conda run -n qiime2"

if [[ -f "/opt/conda/envs/preproc/bin/fastp" ]]; then
    export FASTP_BIN="/opt/conda/envs/preproc/bin/fastp"
elif [[ -f "/usr/local/bin/fastp" ]]; then
    export FASTP_BIN="/usr/local/bin/fastp"
else
    export FASTP_BIN="fastp"
fi

if [[ -f "/opt/conda/envs/preproc/bin/multiqc" ]]; then
    export MULTIQC_BIN="/opt/conda/envs/preproc/bin/multiqc"
else
    export MULTIQC_BIN="multiqc"
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

export PROJECT_NAME="$1"
export BASE_DIR="/home/proyecto"
export PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

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

# Inicializar logs
echo "step,start_time,end_time,duration_seconds,duration_minutes,max_memory_kb,max_memory_mb,max_memory_gb,cpu_percent,io_read_mb,io_write_mb,io_total_mb,exit_status" > "$TIMING_LOG"
echo "timestamp,step,cpu_user,cpu_system,cpu_idle,memory_used_mb,memory_free_mb,disk_read_mb,disk_write_mb" > "$SYSTEM_SUMMARY"

declare -A STEP_IO_READ
declare -A STEP_IO_WRITE

# --- FUNCIONES DE MONITOREO ---
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
# VERIFICACIÓN DE DIRECTORIOS
# ============================================================================

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

export RAW_DIR="$PROJECT_DIR/raw_sequences"
export QIIME_DIR="$PROJECT_DIR/qiime2_results"
export RESULTS_DIR="$PROJECT_DIR/results"
export METADATA_FILE="$PROJECT_DIR/metadata.tsv"

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

export QC_DIR="$PROJECT_DIR/qc_reports"
export CLEAN_DIR="$PROJECT_DIR/cleaned_sequences"
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
    -i "$fq1" -I "$fq2" -o "$out1" -O "$out2" \
    --trim_front1 $FASTP_TRIM_FRONT1 --trim_front2 $FASTP_TRIM_FRONT2 \
    $([ "$FASTP_CUT_TAIL" = true ] && echo "--cut_tail") \
    --qualified_quality_phred $FASTP_QUALITY_PHRED \
    --length_required $FASTP_LENGTH_REQUIRED \
    --thread $FASTP_THREADS \
    $([ "$FASTP_DETECT_ADAPTERS" = true ] && echo "--detect_adapter_for_pe") \
    --json "$json" --html "$html" --compression 6 2>/dev/null

  if [[ ! -s "$out1" ]]; then
     echo "ERROR: Falló fastp para $sample_id. Archivo vacío." >&2
     exit 1
  fi
  
  echo "  ✓ $sample_id completado"
}
export -f process_fastp_sample

ALL_SAMPLES_LIST="$TMPDIR/all_samples_list.txt"
> "$ALL_SAMPLES_LIST"

for GRUPO in "${GRUPOS[@]}"; do
  GRUPO_RAW="$RAW_DIR/$GRUPO"
  for fq1 in "$GRUPO_RAW"/*_1.fq.gz; do
    if [[ -f "$fq1" ]]; then
      fq2="${fq1/_1.fq.gz/_2.fq.gz}"
      [[ -f "$fq2" ]] || continue
      sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
      printf "%s\t%s\t%s\t%s\n" "$fq1" "$fq2" "$sample_id" "$GRUPO" >> "$ALL_SAMPLES_LIST"
    fi
  done
done

FASTP_CMD="cat '$ALL_SAMPLES_LIST' | parallel -j 3 --colsep '\t' --will-cite 'process_fastp_sample {1} {2} {3} {4}'"
run_monitored "1_Preproc_fastp" "$FASTP_CMD"

echo ""
echo "=========================================="
echo "PASO 2: REPORTE MULTIQC"
echo "=========================================="
echo ""

MULTIQC_CMD="$MULTIQC_BIN '$QC_DIR' -o '$QC_DIR' -n multiqc_report.html --force"
run_monitored "2_Reporte_MultiQC" "$MULTIQC_CMD"

echo ""
echo "=========================================="
echo "PASO 3: DADA2 (Denoising)"
echo "=========================================="
echo ""
export BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

step_dada2_processing() {
    local GRUPOS=($(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort))
    
    for GRUPO in "${GRUPOS[@]}"; do
        echo ">> Procesando Grupo: $GRUPO"
        local GRUPO_CLEAN="$CLEAN_DIR/$GRUPO"
        local GRUPO_OUT="$BASE_DADA2/$GRUPO"
        mkdir -p "$GRUPO_OUT"
        
        local MANIFEST="$GRUPO_OUT/manifest.tsv"
        printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST"
        
        local FOUND_FILES=0
        for fq1 in "$GRUPO_CLEAN"/*_1.fq.gz; do
            if [[ -f "$fq1" ]]; then
                local fq2="${fq1/_1.fq.gz/_2.fq.gz}"
                if [[ -f "$fq2" ]]; then
                    local sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
                    printf "%s\t%s\t%s\n" "$sample_id" "$fq1" "$fq2" >> "$MANIFEST"
                    FOUND_FILES=$((FOUND_FILES + 1))
                fi
            fi
        done
        
        if [[ "$FOUND_FILES" -eq 0 ]]; then
            echo "  ADVERTENCIA: No hay archivos para $GRUPO"
            continue
        fi
        
        $CONDA_QIIME2_RUN qiime tools import \
            --type 'SampleData[PairedEndSequencesWithQuality]' \
            --input-path "$MANIFEST" \
            --output-path "$GRUPO_OUT/demux.qza" \
            --input-format PairedEndFastqManifestPhred33V2
        
        $CONDA_QIIME2_RUN qiime dada2 denoise-paired \
            --i-demultiplexed-seqs "$GRUPO_OUT/demux.qza" \
            --p-trim-left-f $DADA2_TRIM_LEFT_F --p-trim-left-r $DADA2_TRIM_LEFT_R \
            --p-trunc-len-f $DADA2_TRUNC_LEN_F --p-trunc-len-r $DADA2_TRUNC_LEN_R \
            --p-max-ee-f $DADA2_MAX_EE_F --p-max-ee-r $DADA2_MAX_EE_R \
            --p-n-threads $DADA2_THREADS \
            --o-table "$GRUPO_OUT/table.qza" \
            --o-representative-sequences "$GRUPO_OUT/rep-seqs.qza" \
            --o-denoising-stats "$GRUPO_OUT/denoising-stats.qza" \
            --verbose
    done
    
    echo ">> Unificando estadísticas de Denoising..."
    local STATS_TEMP_DIR="$TMPDIR/stats_merge"
    mkdir -p "$STATS_TEMP_DIR"
    local COMBINED_STATS_TSV="$STATS_TEMP_DIR/combined_stats.tsv"
    rm -f "$COMBINED_STATS_TSV"
    local HEADER_WRITTEN=0

    for GRUPO in "${GRUPOS[@]}"; do
        local STATS_QZA="$BASE_DADA2/$GRUPO/denoising-stats.qza"
        if [[ -f "$STATS_QZA" ]]; then
            $CONDA_QIIME2_RUN qiime tools export --input-path "$STATS_QZA" --output-path "$STATS_TEMP_DIR/$GRUPO" 2>/dev/null
            local STATS_TSV="$STATS_TEMP_DIR/$GRUPO/stats.tsv"
            if [[ -f "$STATS_TSV" ]]; then
                if [[ $HEADER_WRITTEN -eq 0 ]]; then
                    cat "$STATS_TSV" > "$COMBINED_STATS_TSV"
                    HEADER_WRITTEN=1
                else
                    grep -v "^sample-id" "$STATS_TSV" | grep -v "^#q2:types" >> "$COMBINED_STATS_TSV" || true
                fi
            fi
        fi
    done

    if [[ -s "$COMBINED_STATS_TSV" ]]; then
        $CONDA_QIIME2_RUN qiime metadata tabulate \
            --m-input-file "$COMBINED_STATS_TSV" \
            --o-visualization "$RESULTS_DIR/denoising-stats-final.qzv"
    fi
}
export -f step_dada2_processing

run_monitored "3_DADA2_Denoising" "step_dada2_processing"

echo ""
echo "=========================================="
echo "PASO 4: Árboles filogenéticos"
echo "=========================================="
echo ""

export BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

build_phylogeny() {
    local grupo=$1
    local grupo_out="$BASE_PHYLO/$grupo"
    mkdir -p "$grupo_out"
    if [[ ! -f "$BASE_DADA2/$grupo/rep-seqs.qza" ]]; then return; fi

    $CONDA_QIIME2_RUN qiime phylogeny align-to-tree-mafft-fasttree \
        --i-sequences "$BASE_DADA2/$grupo/rep-seqs.qza" \
        --p-n-threads $PHYLO_THREADS \
        --o-alignment "$grupo_out/aligned-rep-seqs.qza" \
        --o-masked-alignment "$grupo_out/masked-aligned-rep-seqs.qza" \
        --o-tree "$grupo_out/unrooted-tree.qza" \
        --o-rooted-tree "$grupo_out/rooted-tree.qza" --verbose 2>&1
}
export -f build_phylogeny

PHYLO_CMD="echo '${GRUPOS[@]}' | tr ' ' '\n' | parallel -j 3 --will-cite 'build_phylogeny {}'"
run_monitored "4_Arboles_Filogeneticos" "$PHYLO_CMD"

echo ""
echo "=========================================="
echo "PASO 5: Análisis de Diversidad"
echo "=========================================="
echo ""
export OUT_DIV="$QIIME_DIR/core_diversity"
export COMBINED_OUT="$OUT_DIV/combined_analysis"
rm -rf "$COMBINED_OUT"
mkdir -p "$COMBINED_OUT"

step_diversity_prep() {
    local GRUPOS=($(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort))
    echo ">> Uniendo Tablas y Secuencias..."
    local MERGE_TABLES_CMD="$CONDA_QIIME2_RUN qiime feature-table merge"
    local MERGE_SEQS_CMD="$CONDA_QIIME2_RUN qiime feature-table merge-seqs"
    
    for GRUPO in "${GRUPOS[@]}"; do
        if [[ -f "$BASE_DADA2/$GRUPO/table.qza" ]]; then
            MERGE_TABLES_CMD="$MERGE_TABLES_CMD --i-tables $BASE_DADA2/$GRUPO/table.qza"
            MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
        fi
    done
    
    MERGE_TABLES_CMD="$MERGE_TABLES_CMD --o-merged-table $COMBINED_OUT/merged_table.qza"
    MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"
    
    $MERGE_TABLES_CMD
    $MERGE_SEQS_CMD
    
    echo ">> Generando Árbol Filogenético Final..."
    $CONDA_QIIME2_RUN qiime phylogeny align-to-tree-mafft-fasttree \
        --i-sequences "$COMBINED_OUT/merged_rep-seqs.qza" \
        --p-n-threads 12 \
        --o-alignment "$COMBINED_OUT/aligned-rep-seqs.qza" \
        --o-masked-alignment "$COMBINED_OUT/masked-aligned-rep-seqs.qza" \
        --o-tree "$COMBINED_OUT/unrooted-tree.qza" \
        --o-rooted-tree "$COMBINED_OUT/rooted-tree.qza" \
        --verbose
}
export -f step_diversity_prep

run_monitored "5_Arbol_Diversidad" "step_diversity_prep"

echo ""
echo "=========================================="
echo "PASO 6: Métricas Core"
echo "=========================================="
echo ""

CMD_CORE_METRICS=(
  $CONDA_QIIME2_RUN qiime diversity core-metrics-phylogenetic
  --i-table "$COMBINED_OUT/merged_table.qza"
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza"
  --m-metadata-file "$METADATA_FILE"
  --p-sampling-depth $SAMPLING_DEPTH
  --output-dir "$COMBINED_OUT/results"
  --verbose
)
run_monitored "6_Metricas" "${CMD_CORE_METRICS[*]}"

echo ""
echo "=========================================="
echo "PASO 7: Visualizaciones de Resultados"
echo "=========================================="
echo ""

export METADATA_INDIVIDUAL="$PROJECT_DIR/metadata_individual_samples.tsv"

# Crear metadatos modificados
ID_COL_NAME=$(head -n 1 "$METADATA_FILE" | cut -f1)
awk -F'\t' 'BEGIN {OFS="\t"} 
    NR==1 {print $0, "Muestra_Unica"} 
    NR==2 {print $0, "categorical"} 
    NR>2 {print $0, $1}' "$METADATA_FILE" > "$METADATA_INDIVIDUAL"

step_visualizations_all() {
    # 1. Significancia de Grupos
    echo ">> Generando Significancia por Grupos..."
    for metric in shannon evenness faith_pd observed_features; do
        if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
            $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
                --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
                --m-metadata-file "$METADATA_FILE" \
                --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
        fi
    done
    
    # 2. Rarefacción General
    echo ">> Generando Rarefacción General..."
    $CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
        --i-table "$COMBINED_OUT/merged_table.qza" \
        --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
        --m-metadata-file "$METADATA_FILE" \
        --p-max-depth $SAMPLING_DEPTH \
        --p-steps 20 \
        --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

    # 3. Rarefacción Individual
    echo ">> Generando Rarefacción Individual..."
    $CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
        --i-table "$COMBINED_OUT/merged_table.qza" \
        --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
        --m-metadata-file "$METADATA_INDIVIDUAL" \
        --p-max-depth $SAMPLING_DEPTH \
        --p-steps 20 \
        --o-visualization "$RESULTS_DIR/alpha-rarefaction-INDIVIDUAL.qzv"

    # 4. Significancia Individual
    echo ">> Generando Plots Alpha Individuales..."
    for metric in shannon evenness faith_pd observed_features; do
        if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
            $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
                --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
                --m-metadata-file "$METADATA_INDIVIDUAL" \
                --o-visualization "$RESULTS_DIR/${metric}-individual-samples.qzv"
        fi
    done

    # 5. Beta Individual
    echo ">> Generando Plots Beta Individuales..."
    for pcoa in "$COMBINED_OUT/results/"*_pcoa_results.qza; do
        if [[ -f "$pcoa" ]]; then
            BASE_NAME=$(basename "$pcoa" _pcoa_results.qza)
            $CONDA_QIIME2_RUN qiime emperor plot \
                --i-pcoa "$pcoa" \
                --m-metadata-file "$METADATA_INDIVIDUAL" \
                --o-visualization "$RESULTS_DIR/${BASE_NAME}_emperor_individual.qzv"
        fi
    done
}
export -f step_visualizations_all

run_monitored "7_Visualizaciones" "step_visualizations_all"

echo ""
echo "=========================================="
echo "PASO 8: Generación de Tablas Maestras"
echo "=========================================="
echo ""

step_final_tables() {
    echo ">> Generando Tabla Maestra Alpha (Datos)..."
    local CMD_ALPHA=( $CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file "$METADATA_FILE" )
    for f in "$COMBINED_OUT/results/"*_vector.qza; do
        if [[ -f "$f" ]]; then CMD_ALPHA+=( --m-input-file "$f" ); fi
    done
    CMD_ALPHA+=( --o-visualization "$RESULTS_DIR/TABLA_FINAL_ALPHA_MUESTRAS.qzv" )
    "${CMD_ALPHA[@]}"

    echo ">> Generando Tablas Coordenadas PCoA..."
    for f in "$COMBINED_OUT/results/"*_pcoa_results.qza; do
        if [[ -f "$f" ]]; then
            local BASE_NAME=$(basename "$f" .qza)
            $CONDA_QIIME2_RUN qiime metadata tabulate \
                --m-input-file "$METADATA_FILE" \
                --m-input-file "$f" \
                --o-visualization "$RESULTS_DIR/TABLA_COORDENADAS_${BASE_NAME}.qzv" || true
        fi
    done
    
    find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true
}
export -f step_final_tables

run_monitored "8_Exportar_Tablas" "step_final_tables"

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