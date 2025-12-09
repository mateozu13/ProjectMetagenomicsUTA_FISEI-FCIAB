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

if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  exit 1
fi

PROJECT_NAME="$1"
BASE_DIR="/home/proyecto"
PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

echo "=========================================="
echo "Pipeline OPTIMIZADO con GNU Parallel"
echo "=========================================="
echo "Proyecto: $PROJECT_NAME"
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

mkdir -p "$PREPROC_DIR" "$QIIME_DIR" "$RESULTS_DIR"

GRUPOS=()
while IFS= read -r dir; do GRUPOS+=("$(basename "$dir")"); done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

process_fastp_sample() {
    local grupo=$1
    local r1_file=$2
    local sample_id=$3
    local r2_file="${r1_file/_1.fq.gz/_2.fq.gz}"
    
    local out_dir="$PREPROC_DIR/$grupo"
    mkdir -p "$out_dir"
    
    local out_r1="$out_dir/${sample_id}_filtered_1.fq.gz"
    local out_r2="$out_dir/${sample_id}_filtered_2.fq.gz"
    local json_report="$out_dir/${sample_id}_fastp.json"
    local html_report="$out_dir/${sample_id}_fastp.html"
    
    echo "  Procesando: $sample_id ($grupo)"
    
    "$FASTP_BIN" \
        -i "$r1_file" -I "$r2_file" \
        -o "$out_r1" -O "$out_r2" \
        --trim_front1 $FASTP_TRIM_FRONT1 --trim_front2 $FASTP_TRIM_FRONT2 \
         --qualified_quality_phred $FASTP_QUALITY_PHRED \
        --thread $FASTP_THREADS 2>/dev/null \
        --json "$json_report" \
        --html "$html_report" 2>/dev/null | \
}
export -f process_fastp_sample
export PREPROC_DIR FASTP_BIN FASTP_THREADS FASTP_TRIM_FRONT1 FASTP_TRIM_FRONT2
export FASTP_QUALITY_PHRED FASTP_LENGTH_REQUIREDd
echo "=========================================="
echo "PASO 1: Preprocesamiento PARALELO con fastp"
echo "=========================================="
echo ""
find "$RAW_DIR" -name "*_1.fq.gz" | \
while read fq1; do
    grupo=$(basename $(dirname "$fq1"))
    sample_id=$(basename "$fq1" | sed 's/_1\.fq\.gz$//')
    printf "%s\t%s\t%s\n" "$grupo" "$fq1" "$sample_id"
done | parallel -j 3 --colsep '\t' --will-cite 'process_fastp_sample {1} {2} {3}'

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

echo "PASO 2: DADA2 denoising"
for GRUPO in "${GRUPOS[@]}"; do
  echo "  Grupo: $GRUPO"
  GRUPO_OUT="$BASE_DADA2/$GRUPO"
  mkdir -p "$GRUPO_OUT"
  MANIFEST="$GRUPO_OUT/manifest.tsv"
  
  printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST"
  
  COUNT=0
  for r1 in "$PREPROC_DIR/$GRUPO"/*_1.fq.gz; do
    if [[ -f "$r1" ]]; then
        sample=$(basename "$r1" | sed 's/_filtered_1\.fq\.gz$//')
        r2="${r1/_1.fq.gz/_2.fq.gz}"
        printf "%s\t%s\t%s\n" "$sample" "$r1" "$r2" >> "$MANIFEST"
        COUNT=$((COUNT+1))
    fi
  done
  
  if [[ "$COUNT" -eq 0 ]]; then
     echo "  ADVERTENCIA: No se encontraron archivos para $GRUPO."
     continue
  fi
  
  $CONDA_QIIME2_RUN qiime tools import --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" --input-format PairedEndFastqManifestPhred33V2 \
    --output-path "$GRUPO_OUT/paired-end-demux.qza"
  
  $CONDA_QIIME2_RUN qiime dada2 denoise-paired --i-demultiplexed-seqs "$GRUPO_OUT/paired-end-demux.qza" \
    --p-trim-left-f $DADA2_TRIM_LEFT_F --p-trim-left-r $DADA2_TRIM_LEFT_R \
    --p-trunc-len-f $DADA2_TRUNC_LEN_F --p-trunc-len-r $DADA2_TRUNC_LEN_R \
    --p-max-ee-f $DADA2_MAX_EE_F --p-max-ee-r $DADA2_MAX_EE_R \
    --p-n-threads $DADA2_THREADS --o-table "$GRUPO_OUT/table.qza" \
    --o-representative-sequences "$GRUPO_OUT/rep-seqs.qza" \
    --o-denoising-stats "$GRUPO_OUT/denoising-stats.qza"
done

echo "Unificando estadísticas de DADA2..."
STATS_TEMP_DIR="$TMPDIR/stats_merge"
mkdir -p "$STATS_TEMP_DIR"
COMBINED_STATS_TSV="$STATS_TEMP_DIR/combined_stats.tsv"
rm -f "$COMBINED_STATS_TSV"
HEADER_WRITTEN=0

for GRUPO in "${GRUPOS[@]}"; do
  STATS_QZA="$BASE_DADA2/$GRUPO/denoising-stats.qza"
  if [[ -f "$STATS_QZA" ]]; then
     $CONDA_QIIME2_RUN qiime tools export --input-path "$STATS_QZA" --output-path "$STATS_TEMP_DIR/$GRUPO" 2>/dev/null
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
fi

# (Pasos de Filogenia y Diversidad Estándar)
# ... [Se asume que los pasos estándar siguen aquí, igual que en versiones previas] ...
# Para abreviar, incluyo directamente la lógica de individualización:

OUT_DIV="$QIIME_DIR/core_diversity"
COMBINED_OUT="$OUT_DIV/combined_analysis"

# --- NUEVO: VISUALIZACIONES INDIVIDUALES ---
echo "Generando visualizaciones INDIVIDUALES..."
INDIVIDUAL_DIR="$RESULTS_DIR/graficos_individuales"
mkdir -p "$INDIVIDUAL_DIR"
METADATA_INDIVIDUAL="$PROJECT_DIR/metadata_individual_samples.tsv"

ID_COL_NAME=$(head -n 1 "$METADATA_FILE" | cut -f1)
awk -F'\t' 'BEGIN {OFS="\t"} 
    NR==1 {print $0, "Muestra_Unica"} 
    NR==2 {print $0, "categorical"} 
    NR>2 {print $0, $1}' "$METADATA_FILE" > "$METADATA_INDIVIDUAL"

$CONDA_QIIME2_RUN qiime diversity alpha-rarefaction \
    --i-table "$COMBINED_OUT/merged_table.qza" \
    --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
    --m-metadata-file "$METADATA_INDIVIDUAL" \
    --p-max-depth $SAMPLING_DEPTH \
    --p-steps 20 \
    --o-visualization "$INDIVIDUAL_DIR/alpha-rarefaction-INDIVIDUAL.qzv"

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    $CONDA_QIIME2_RUN qiime diversity alpha-group-significance \
        --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
        --m-metadata-file "$METADATA_INDIVIDUAL" \
        --o-visualization "$INDIVIDUAL_DIR/${metric}-individual-samples.qzv"
  fi
done

# --- NUEVO: TABLAS MAESTRAS ---
echo "Generando tablas de datos crudos..."
CMD_ALPHA_MASTER=( $CONDA_QIIME2_RUN qiime metadata tabulate --m-input-file "$METADATA_FILE" )
for f in "$COMBINED_OUT/results/"*_vector.qza; do
    if [[ -f "$f" ]]; then CMD_ALPHA_MASTER+=( --m-input-file "$f" ); fi
done
CMD_ALPHA_MASTER+=( --o-visualization "$RESULTS_DIR/TABLA_FINAL_ALPHA_MUESTRAS.qzv" )
"${CMD_ALPHA_MASTER[@]}"

echo "=========================================="
echo "✓ PIPELINE COMPLETADO"
echo "=========================================="
echo ""
echo "Resultados en: $RESULTS_DIR"
echo "=========================================="