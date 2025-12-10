#!/usr/bin/env bash
################################################################################
# Pipeline optimizado de análisis metagenómico
# Incluye: Preprocesamiento paralelo, DADA2, filogenia, diversidad
#
# Uso: bash pipeline_optimized_parallel.sh <nombre_proyecto> [config_file]
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

# Configuración de entornos y ejecutables
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
# INICIO DEL PIPELINE
# ============================================================================

PIPELINE_START=$(date +%s)
PIPELINE_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "╔══════════════════════════════════════╗"
echo "║         PIPELINE OPTIMIZADO          ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Proyecto: $PROJECT_NAME"
echo "Directorio: $PROJECT_DIR"
echo "Hora de inicio: $PIPELINE_START_DATETIME"
echo ""
echo "OPTIMIZACIONES ACTIVAS:"
echo "----------------------"
echo "✓ GNU Parallel para procesamiento simultáneo"
echo "✓ tmpfs para archivos temporales"
echo "✓ Generación de gráficos individuales y grupales"
echo ""

# ============================================================================
# VERIFICACIÓN
# ============================================================================

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: No existe el directorio del proyecto: $PROJECT_DIR"
  exit 1
fi

RAW_DIR="$PROJECT_DIR/raw_sequences"
QIIME_DIR="$PROJECT_DIR/qiime2_results"
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
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
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
    --json "$json" --html "$html" \
    --compression 6 \
    2>/dev/null

  if [[ ! -s "$out1" ]]; then
     echo "ERROR: Falló fastp para $sample_id. Archivo vacío." >&2
     exit 1
  fi
  
  echo "  ✓ $sample_id completado"
}
export -f process_fastp_sample
export FASTP_BIN CLEAN_DIR QC_DIR FASTP_TRIM_FRONT1 FASTP_TRIM_FRONT2 FASTP_CUT_TAIL FASTP_QUALITY_PHRED FASTP_LENGTH_REQUIRED FASTP_THREADS FASTP_DETECT_ADAPTERS TMPDIR

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

cat "$ALL_SAMPLES_LIST" | parallel -j 3 --colsep '\t' --will-cite 'process_fastp_sample {1} {2} {3} {4}'

echo "✓ Preprocesamiento completado"

echo ""
echo "=========================================="
echo "PASO 2: REPORTE MULTIQC"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

eval "$MULTIQC_BIN '$QC_DIR' -o '$QC_DIR' -n multiqc_report.html --force"

echo "✓ Reporte MultiQC generado"

echo ""
echo "=========================================="
echo "PASO 3: DADA2 (Denoising)"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

for GRUPO in "${GRUPOS[@]}"; do
  echo "Preparando grupo: $GRUPO"
  GRUPO_CLEAN="$CLEAN_DIR/$GRUPO"
  GRUPO_OUT="$BASE_DADA2/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  
  MANIFEST="$GRUPO_OUT/manifest.tsv"
  printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST"
  
  FOUND_FILES=0
  for fq1 in "$GRUPO_CLEAN"/*_1.fq.gz; do
    if [[ -f "$fq1" ]]; then
      fq2="${fq1/_1.fq.gz/_2.fq.gz}"
      if [[ -f "$fq2" ]]; then
        sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
        printf "%s\t%s\t%s\n" "$sample_id" "$fq1" "$fq2" >> "$MANIFEST"
        FOUND_FILES=$((FOUND_FILES + 1))
      fi
    fi
  done
  
  if [[ "$FOUND_FILES" -eq 0 ]]; then
      echo "ADVERTENCIA: No se encontraron archivos fastq limpios para $GRUPO"
      continue
  fi
  
  $CONDA_QIIME2_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --output-path "$GRUPO_OUT/demux.qza" \
    --input-format PairedEndFastqManifestPhred33V2
  
  $CONDA_QIIME2_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$GRUPO_OUT/demux.qza" \
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
    
  echo "  ✓ DADA2 completado para $GRUPO"
done

# --- UNIFICACIÓN DE ESTADÍSTICAS ---
echo "Unificando estadísticas de DADA2 (Concatenación TSV)..."
STATS_TEMP_DIR="$TMPDIR/stats_merge"
mkdir -p "$STATS_TEMP_DIR"
COMBINED_STATS_TSV="$STATS_TEMP_DIR/combined_stats.tsv"
rm -f "$COMBINED_STATS_TSV"

HEADER_WRITTEN=0

for GRUPO in "${GRUPOS[@]}"; do
  STATS_QZA="$BASE_DADA2/$GRUPO/denoising-stats.qza"
  if [[ -f "$STATS_QZA" ]]; then
     $CONDA_QIIME2_RUN qiime tools export \
        --input-path "$STATS_QZA" \
        --output-path "$STATS_TEMP_DIR/$GRUPO" 2>/dev/null
     
     STATS_TSV="$STATS_TEMP_DIR/$GRUPO/stats.tsv"
     
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
    echo "✓ Estadísticas unificadas"
else
    echo "ERROR: No se pudieron unir las estadísticas."
fi

echo ""
echo "=========================================="
echo "PASO 4: Árboles filogenéticos"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

BASE_PHYLO="$QIIME_DIR/phylogeny"
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
        --o-rooted-tree "$grupo_out/rooted-tree.qza" \
        --verbose 2>&1
}
export -f build_phylogeny
export BASE_PHYLO BASE_DADA2 CONDA_QIIME2_RUN PHYLO_THREADS

echo "${GRUPOS[@]}" | tr ' ' '\n' | parallel -j 3 --will-cite 'build_phylogeny {}'

echo "✓ Árboles filogenéticos completados"

echo ""
echo "=========================================="
echo "PASO 5: Análisis de Diversidad"
echo "=========================================="
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
OUT_DIV="$QIIME_DIR/core_diversity"
COMBINED_OUT="$OUT_DIV/combined_analysis"
rm -rf "$COMBINED_OUT"
mkdir -p "$COMBINED_OUT"

MERGE_TABLES_CMD="$CONDA_QIIME2_RUN qiime feature-table merge"
MERGE_SEQS_CMD="$CONDA_QIIME2_RUN qiime feature-table merge-seqs"
for GRUPO in "${GRUPOS[@]}"; do
  [[ -f "$BASE_DADA2/$GRUPO/table.qza" ]] && MERGE_TABLES_CMD="$MERGE_TABLES_CMD --i-tables $BASE_DADA2/$GRUPO/table.qza"
  [[ -f "$BASE_DADA2/$GRUPO/rep-seqs.qza" ]] && MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
done

MERGE_TABLES_CMD="$MERGE_TABLES_CMD --o-merged-table $COMBINED_OUT/merged_table.qza"
MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"

eval $MERGE_TABLES_CMD
eval $MERGE_SEQS_CMD

$CONDA_QIIME2_RUN qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences "$COMBINED_OUT/merged_rep-seqs.qza" \
  --p-n-threads 12 \
  --o-alignment "$COMBINED_OUT/aligned-rep-seqs.qza" \
  --o-masked-alignment "$COMBINED_OUT/masked-aligned-rep-seqs.qza" \
  --o-tree "$COMBINED_OUT/unrooted-tree.qza" \
  --o-rooted-tree "$COMBINED_OUT/rooted-tree.qza" \
  --verbose

$CONDA_QIIME2_RUN qiime diversity core-metrics-phylogenetic \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir "$COMBINED_OUT/results" \
  --verbose

echo "Generando visualizaciones de grupos..."
for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
        --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
        --m-metadata-file "$METADATA_FILE" \
        --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
  fi
done

$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-max-depth $SAMPLING_DEPTH \
  --p-steps 20 \
  --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

echo "Generando visualizaciones INDIVIDUALES (por muestra)..."
METADATA_INDIVIDUAL="$PROJECT_DIR/metadata_individual_samples.tsv"

# Crear metadatos modificados
ID_COL_NAME=$(head -n 1 "$METADATA_FILE" | cut -f1)
awk -F'\t' 'BEGIN {OFS="\t"} 
    NR==1 {print $0, "Muestra_Unica"} 
    NR==2 {print $0, "categorical"} 
    NR>2 {print $0, $1}' "$METADATA_FILE" > "$METADATA_INDIVIDUAL"

# Alpha Rarefaction Individual
$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
    --i-table "$COMBINED_OUT/merged_table.qza" \
    --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
    --m-metadata-file "$METADATA_INDIVIDUAL" \
    --p-max-depth $SAMPLING_DEPTH \
    --p-steps 20 \
    --o-visualization "$RESULTS_DIR/alpha-rarefaction-individual.qzv"

# Alpha Significance Individual
for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
        --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
        --m-metadata-file "$METADATA_INDIVIDUAL" \
        --o-visualization "$RESULTS_DIR/${metric}-individual-samples.qzv"
  fi
done

# Beta PCoA Individual
for pcoa in "$COMBINED_OUT/results/"*_pcoa_results.qza; do
    if [[ -f "$pcoa" ]]; then
        BASE_NAME=$(basename "$pcoa" _pcoa_results.qza)
        
        $CONDA_QIIME2_RUN qiime emperor plot \
            --i-pcoa "$pcoa" \
            --m-metadata-file "$METADATA_INDIVIDUAL" \
            --o-visualization "$RESULTS_DIR/${BASE_NAME}_emperor_individual.qzv"
    fi
done

echo "Generando TABLA MAESTRA de Alpha Diversidad (datos numéricos)..."
CMD_ALPHA_MASTER=( $CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file "$METADATA_FILE" )
for f in "$COMBINED_OUT/results/"*_vector.qza; do
    if [[ -f "$f" ]]; then
        CMD_ALPHA_MASTER+=( --m-input-file "$f" )
    fi
done
CMD_ALPHA_MASTER+=( --o-visualization "$RESULTS_DIR/TABLA_FINAL_ALPHA_MUESTRAS.qzv" )
"${CMD_ALPHA_MASTER[@]}"

echo "Generando tablas de Coordenadas Beta individuales..."
for f in "$COMBINED_OUT/results/"*_pcoa_results.qza; do
    if [[ -f "$f" ]]; then
        BASE_NAME=$(basename "$f" .qza)
        $CONDA_QIIME2_RUN qiime metadata tabulate \
            --m-input-file "$METADATA_FILE" \
            --m-input-file "$f" \
            --o-visualization "$RESULTS_DIR/TABLA_COORDENADAS_${BASE_NAME}.qzv" || true
    fi
done

find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

# ============================================================================
# FINALIZACIÓN
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
echo "Resultados disponibles en:"
echo "  - Resultados generales:  $RESULTS_DIR"
echo "  - Gráficos Individuales: $RESULTS_DIR"
echo ""
echo "Archivos de interés:"
echo "  1. Tabla Alpha (todas las métricas): TABLA_FINAL_ALPHA_MUESTRAS.qzv"
echo "  2. Visualizaciones individuales:     *-individual.qzv"
echo "  3. Estadísticas denoising:           denoising-stats-final.qzv"
echo ""
echo "═══════════════════════════════════════════════"