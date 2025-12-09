#!/usr/bin/env bash
################################################################################
# Pipeline optimizado de análisis metagenómico
# Incluye: Preprocesamiento paralelo, DADA2, filogenia, diversidad
# 
# Uso: bash pipeline_optimized_parallel.sh <nombre_proyecto>
# Ejemplo: bash pipeline_optimized_parallel.sh Proyecto_Optimizado
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

# ============================================================================
# VERIFICACIÓN DE ARGUMENTOS
# ============================================================================

if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto>"
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

# ============================================================================
# INICIO DEL PIPELINE
# ============================================================================

PIPELINE_START=$(date +%s)
PIPELINE_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║         PIPELINE OPTIMIZADO PARALELO         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo "Hora de inicio: $PIPELINE_START_DATETIME"
echo ""
echo "OPTIMIZACIONES ACTIVAS:"
echo "----------------------"
echo "✓ GNU Parallel para procesamiento simultáneo"
echo "✓ tmpfs para archivos temporales"
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

GRUPOS=()
while IFS= read -r dir; do
    GRUPOS+=("$(basename "$dir")")
done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

echo "Grupos detectados: ${GRUPOS[@]}"
echo "Usando fastp en: $FASTP_BIN"
echo ""

# ============================================================================
# PASO 1: CONTROL DE CALIDAD CON FASTP (PARALELO)
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 1: Control de Calidad (fastp)"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

CLEAN_DIR="$PROJECT_DIR/cleaned_sequences"
QC_DIR="$PROJECT_DIR/qc_reports"
mkdir -p "$CLEAN_DIR"
mkdir -p "$QC_DIR"

process_fastp_sample() {
    local grupo=$1
    local r1_file=$2
    local sample_id=$3
    local r2_file="${r1_file/_1.fq.gz/_2.fq.gz}"
    
    local out_dir="$CLEAN_DIR/$grupo"
    mkdir -p "$out_dir"
    
    local out_r1="$out_dir/${sample_id}_1.fq.gz"
    local out_r2="$out_dir/${sample_id}_2.fq.gz"
    local json_report="$QC_DIR/${sample_id}_fastp.json"
    local html_report="$QC_DIR/${sample_id}_fastp.html"
    
    echo "  Procesando: $sample_id ($grupo)"
    
    local fastp_cmd="$FASTP_BIN -i '$r1_file' -I '$r2_file' -o '$out_r1' -O '$out_r2' --trim_front1 $FASTP_TRIM_FRONT1 --trim_front2 $FASTP_TRIM_FRONT2"
    
    if [ "$FASTP_CUT_TAIL" = true ]; then
        fastp_cmd="$fastp_cmd --cut_tail"
    fi
    
    fastp_cmd="$fastp_cmd --qualified_quality_phred $FASTP_QUALITY_PHRED --length_required $FASTP_LENGTH_REQUIRED --thread $FASTP_THREADS"
    
    if [ "$FASTP_DETECT_ADAPTERS" = true ]; then
        fastp_cmd="$fastp_cmd --detect_adapter_for_pe"
    fi
    
    fastp_cmd="$fastp_cmd --json '$json_report' --html '$html_report'"
    
    eval $fastp_cmd 2>/dev/null
}

export -f process_fastp_sample
export CLEAN_DIR QC_DIR FASTP_BIN FASTP_THREADS FASTP_TRIM_FRONT1 FASTP_TRIM_FRONT2 FASTP_CUT_TAIL FASTP_QUALITY_PHRED FASTP_LENGTH_REQUIRED FASTP_DETECT_ADAPTERS

find "$RAW_DIR" -name "*_1.fq.gz" | \
while read fq1; do
    grupo=$(basename $(dirname "$fq1"))
    sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
    printf "%s\t%s\t%s\n" "$grupo" "$fq1" "$sample_id"
done | parallel -j 3 --colsep '\t' --will-cite 'process_fastp_sample {1} {2} {3}'

echo "✓ Control de Calidad completado"
echo ""

# ============================================================================
# PASO 2: IMPORTACIÓN A QIIME2 (TODAS LAS MUESTRAS)
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 2: Importación a QIIME2"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"
ALL_SAMPLES_OUT="$BASE_DADA2/todas_muestras"
mkdir -p "$ALL_SAMPLES_OUT"

MANIFEST="$ALL_SAMPLES_OUT/manifest.tsv"
printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST"

COUNT=0
for GRUPO in "${GRUPOS[@]}"; do
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

$CONDA_QIIME2_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --input-format PairedEndFastqManifestPhred33V2 \
    --output-path "$ALL_SAMPLES_OUT/demux.qza"

echo "✓ Importación completada"
echo ""

# ============================================================================
# PASO 3: DADA2 DENOISING (TODAS LAS MUESTRAS JUNTAS)
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 3: DADA2 Denoising"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

$CONDA_QIIME2_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$ALL_SAMPLES_OUT/demux.qza" \
    --p-trim-left-f $DADA2_TRIM_LEFT_F \
    --p-trim-left-r $DADA2_TRIM_LEFT_R \
    --p-trunc-len-f $DADA2_TRUNC_LEN_F \
    --p-trunc-len-r $DADA2_TRUNC_LEN_R \
    --p-max-ee-f $DADA2_MAX_EE_F \
    --p-max-ee-r $DADA2_MAX_EE_R \
    --p-n-threads $DADA2_THREADS \
    --o-table "$ALL_SAMPLES_OUT/table.qza" \
    --o-representative-sequences "$ALL_SAMPLES_OUT/rep-seqs.qza" \
    --o-denoising-stats "$ALL_SAMPLES_OUT/denoising-stats.qza" \
    --verbose

$CONDA_QIIME2_RUN qiime metadata tabulate \
    --m-input-file "$ALL_SAMPLES_OUT/denoising-stats.qza" \
    --o-visualization "$RESULTS_DIR/denoising-stats-final.qzv"

echo "✓ DADA2 Denoising completado"
echo ""

# ============================================================================
# PASO 4: FILOGENIA
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 4: Construcción Árbol Filogenético"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

$CONDA_QIIME2_RUN qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences "$ALL_SAMPLES_OUT/rep-seqs.qza" \
    --p-n-threads $PHYLO_THREADS \
    --o-alignment "$BASE_PHYLO/aligned-rep-seqs.qza" \
    --o-masked-alignment "$BASE_PHYLO/masked-aligned-rep-seqs.qza" \
    --o-tree "$BASE_PHYLO/unrooted-tree.qza" \
    --o-rooted-tree "$BASE_PHYLO/rooted-tree.qza" \
    --verbose

echo "✓ Árbol Filogenético completado"
echo ""

# ============================================================================
# PASO 5: ANÁLISIS DE DIVERSIDAD
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 5: Análisis de Diversidad Core"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

OUT_DIV="$QIIME_DIR/core_diversity"
mkdir -p "$OUT_DIV"

$CONDA_QIIME2_RUN qiime diversity core-metrics-phylogenetic \
    --i-table "$ALL_SAMPLES_OUT/table.qza" \
    --i-phylogeny "$BASE_PHYLO/rooted-tree.qza" \
    --m-metadata-file "$METADATA_FILE" \
    --p-sampling-depth $SAMPLING_DEPTH \
    --output-dir "$OUT_DIV" \
    --verbose

echo "✓ Métricas Core completadas"
echo ""

# ============================================================================
# PASO 6: VISUALIZACIONES GRUPALES
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 6: Visualizaciones Grupales"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$OUT_DIV/${metric}_vector.qza" ]]; then
    echo "  Generando: ${metric}-group-significance.qzv"
    $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
        --i-alpha-diversity "$OUT_DIV/${metric}_vector.qza" \
        --m-metadata-file "$METADATA_FILE" \
        --o-visualization "$RESULTS_DIR/${metric}-group-significance.qzv"
  fi
done

echo "  Generando: alpha-rarefaction.qzv"
$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
    --i-table "$ALL_SAMPLES_OUT/table.qza" \
    --i-phylogeny "$BASE_PHYLO/rooted-tree.qza" \
    --m-metadata-file "$METADATA_FILE" \
    --p-max-depth $SAMPLING_DEPTH \
    --p-steps 20 \
    --o-visualization "$RESULTS_DIR/alpha-rarefaction.qzv"

echo "✓ Visualizaciones Grupales completadas"
echo ""

# ============================================================================
# PASO 7: VISUALIZACIONES INDIVIDUALES
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 7: Visualizaciones Individuales"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

METADATA_INDIVIDUAL="$PROJECT_DIR/metadata_individual_samples.tsv"
ID_COL_NAME=$(head -n 1 "$METADATA_FILE" | cut -f1)
awk -F'\t' 'BEGIN {OFS="\t"} 
    NR==1 {print $0, "Muestra_Unica"} 
    NR==2 {print $0, "categorical"} 
    NR>2 {print $0, $1}' "$METADATA_FILE" > "$METADATA_INDIVIDUAL"

echo "  Generando: alpha-rarefaction-individual.qzv"
$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
    --i-table "$ALL_SAMPLES_OUT/table.qza" \
    --i-phylogeny "$BASE_PHYLO/rooted-tree.qza" \
    --m-metadata-file "$METADATA_INDIVIDUAL" \
    --p-max-depth $SAMPLING_DEPTH \
    --p-steps 20 \
    --o-visualization "$RESULTS_DIR/alpha-rarefaction-individual.qzv"

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$OUT_DIV/${metric}_vector.qza" ]]; then
    echo "  Generando: ${metric}-individual.qzv"
    $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
        --i-alpha-diversity "$OUT_DIV/${metric}_vector.qza" \
        --m-metadata-file "$METADATA_INDIVIDUAL" \
        --o-visualization "$RESULTS_DIR/${metric}-individual.qzv"
  fi
done

for pcoa in "$OUT_DIV/"*_pcoa_results.qza; do
    if [[ -f "$pcoa" ]]; then
        BASE_NAME=$(basename "$pcoa" _pcoa_results.qza)
        echo "  Generando: ${BASE_NAME}_emperor_individual.qzv"
        $CONDA_QIIME2_RUN qiime emperor plot \
            --i-pcoa "$pcoa" \
            --m-metadata-file "$METADATA_INDIVIDUAL" \
            --o-visualization "$RESULTS_DIR/${BASE_NAME}_emperor_individual.qzv" 2>/dev/null || true
    fi
done

echo "✓ Visualizaciones Individuales completadas"
echo ""

# ============================================================================
# PASO 8: TABLAS MAESTRAS
# ============================================================================

echo ""
echo "=========================================="
echo "  PASO 8: Generación Tablas Maestras"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "  Generando: TABLA_FINAL_ALPHA_MUESTRAS.qzv"
CMD_ALPHA_MASTER=( $CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file "$METADATA_FILE" )
for f in "$OUT_DIV/"*_vector.qza; do
    if [[ -f "$f" ]]; then
        CMD_ALPHA_MASTER+=( --m-input-file "$f" )
    fi
done
CMD_ALPHA_MASTER+=( --o-visualization "$RESULTS_DIR/TABLA_FINAL_ALPHA_MUESTRAS.qzv" )
"${CMD_ALPHA_MASTER[@]}"

for f in "$OUT_DIV/"*_pcoa_results.qza; do
    if [[ -f "$f" ]]; then
        BASE_NAME=$(basename "$f" .qza)
        echo "  Generando: TABLA_COORDENADAS_${BASE_NAME}.qzv"
        $CONDA_QIIME2_RUN qiime metadata tabulate \
            --m-input-file "$METADATA_FILE" \
            --m-input-file "$f" \
            --o-visualization "$RESULTS_DIR/TABLA_COORDENADAS_${BASE_NAME}.qzv" 2>/dev/null || true
    fi
done

find "$OUT_DIV" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

echo "✓ Tablas Maestras completadas"
echo ""

# ============================================================================
# RESUMEN FINAL
# ============================================================================

PIPELINE_END=$(date +%s)
PIPELINE_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
PIPELINE_DURATION=$((PIPELINE_END - PIPELINE_START))
PIPELINE_DURATION_MIN=$(echo "scale=2; $PIPELINE_DURATION / 60" | bc)

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           PIPELINE COMPLETADO                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Inicio:          $PIPELINE_START_DATETIME"
echo "Fin:             $PIPELINE_END_DATETIME"
echo "Duración total:  ${PIPELINE_DURATION}s (${PIPELINE_DURATION_MIN} min)"
echo ""
echo "Resultados disponibles en: $RESULTS_DIR"
echo ""
echo "Archivos de interés:"
echo "  1. Tabla Alpha (todas las métricas): TABLA_FINAL_ALPHA_MUESTRAS.qzv"
echo "  2. Visualizaciones individuales:     *-individual.qzv"
echo "  3. Estadísticas denoising:           denoising-stats-final.qzv"
echo ""
echo "═══════════════════════════════════════════════"