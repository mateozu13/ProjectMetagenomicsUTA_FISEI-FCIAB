#!/usr/bin/env bash

set -euo pipefail

FASTP_TRIM_FRONT1=10
FASTP_TRIM_FRONT2=10
FASTP_CUT_TAIL=true
FASTP_QUALITY_PHRED=20
FASTP_LENGTH_REQUIRED=150
FASTP_THREADS=4
FASTP_DETECT_ADAPTERS=true

DADA2_TRIM_LEFT_F=0
DADA2_TRIM_LEFT_R=0
DADA2_TRUNC_LEN_F=230
DADA2_TRUNC_LEN_R=220
DADA2_MAX_EE_F=2.0
DADA2_MAX_EE_R=2.0
DADA2_THREADS=2

SAMPLING_DEPTH=6000
PHYLO_THREADS=4

export TMPDIR="/mnt/fast_tmp"
mkdir -p "$TMPDIR"

CONDA_RUN="/opt/conda/bin/conda run -n qiime2"
FASTP_RUN="/opt/conda/bin/conda run -n preproc fastp"
MULTIQC_RUN="/opt/conda/bin/conda run -n preproc multiqc"


if [[ $# -lt 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto>"
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

mkdir -p "$PREPROC_DIR"
mkdir -p "$QIIME_DIR"
mkdir -p "$RESULTS_DIR"

echo "Detectando grupos de muestras..."
GRUPOS=()
while IFS= read -r dir; do
  GRUPOS+=("$(basename "$dir")")
done < <(find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

echo "Grupos detectados: ${GRUPOS[@]}"
echo ""

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
    
    echo "  Procesando: $sample_id ($grupo)"
    
    pigz -dc "$r1_file" | \
    $FASTP_RUN \
        --stdin \
        --interleaved_in \
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
    pigz -p $FASTP_THREADS > "$out_dir/${sample_id}_filtered_interleaved.fq.gz"
    
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

find "$RAW_DIR" -name "*_1.fq.gz" | \
parallel -j 3 --will-cite --eta \
    'grupo=$(basename $(dirname {})); process_fastp_sample "$grupo" {}'

echo ""
echo "✓ Preprocesamiento paralelo completado"
echo ""

BASE_DADA2="$QIIME_DIR/dada2"
mkdir -p "$BASE_DADA2"

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
  
  for r1 in "$PREPROC_DIR/$GRUPO"/*_1.fq.gz; do
    sample=$(basename "$r1" | sed 's/_filtered_1\.fq\.gz$//')
    r2="${r1/_1.fq.gz/_2.fq.gz}"
    echo -e "$sample\t$r1\t$r2" >> "$MANIFEST"
  done
  
  $CONDA_RUN qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --input-format PairedEndFastqManifestPhred33V2 \
    --output-path "$GRUPO_OUT/paired-end-demux.qza"
  
  $CONDA_RUN qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$GRUPO_OUT/paired-end-demux.qza" \
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
  
  $CONDA_RUN qiime metadata tabulate \
    --m-input-file "$GRUPO_OUT/denoising-stats.qza" \
    --o-visualization "$GRUPO_OUT/denoising-stats.qzv"
  
  echo "  ✓ $GRUPO completado"
  echo ""
done

BASE_PHYLO="$QIIME_DIR/phylogeny"
mkdir -p "$BASE_PHYLO"

echo "=========================================="
echo "PASO 3: Árboles filogenéticos PARALELOS"
echo "=========================================="
echo ""

build_phylogeny() {
    local grupo=$1
    local grupo_out="$BASE_PHYLO/$grupo"
    mkdir -p "$grupo_out"
    
    echo "  Construyendo árbol para: $grupo"
    
    $CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
        --i-sequences "$BASE_DADA2/$grupo/rep-seqs.qza" \
        --p-n-threads $PHYLO_THREADS \
        --o-alignment "$grupo_out/aligned-rep-seqs.qza" \
        --o-masked-alignment "$grupo_out/masked-aligned-rep-seqs.qza" \
        --o-tree "$grupo_out/unrooted-tree.qza" \
        --o-rooted-tree "$grupo_out/rooted-tree.qza" \
        --verbose
}

export -f build_phylogeny
export BASE_PHYLO BASE_DADA2 CONDA_RUN PHYLO_THREADS

echo "${GRUPOS[@]}" | tr ' ' '\n' | \
parallel -j 3 --will-cite 'build_phylogeny {}'

echo ""
echo "✓ Árboles filogenéticos completados"
echo ""

echo "=========================================="
echo "PASO 4: Análisis de diversidad"
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
eval $MERGE_TABLES_CMD

MERGE_SEQS_CMD="$CONDA_RUN qiime feature-table merge-seqs"
for GRUPO in "${GRUPOS[@]}"; do
  MERGE_SEQS_CMD="$MERGE_SEQS_CMD --i-data $BASE_DADA2/$GRUPO/rep-seqs.qza"
done
MERGE_SEQS_CMD="$MERGE_SEQS_CMD --o-merged-data $COMBINED_OUT/merged_rep-seqs.qza"
eval $MERGE_SEQS_CMD

$CONDA_RUN qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences "$COMBINED_OUT/merged_rep-seqs.qza" \
  --p-n-threads 12 \
  --o-alignment "$COMBINED_OUT/aligned-rep-seqs.qza" \
  --o-masked-alignment "$COMBINED_OUT/masked-aligned-rep-seqs.qza" \
  --o-tree "$COMBINED_OUT/unrooted-tree.qza" \
  --o-rooted-tree "$COMBINED_OUT/rooted-tree.qza" \
  --verbose

$CONDA_RUN qiime diversity core-metrics-phylogenetic \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir "$COMBINED_OUT/results" \
  --verbose

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

$CONDA_RUN qiime diversity alpha-rarefaction \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA_FILE" \
  --p-max-depth $SAMPLING_DEPTH \
  --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

echo "✓ Análisis de diversidad completado"
echo ""

echo "=========================================="
echo "PASO 5: Copiando visualizaciones"
echo "=========================================="

for GRUPO in "${GRUPOS[@]}"; do
  if [[ -f "$BASE_DADA2/$GRUPO/denoising-stats.qzv" ]]; then
    cp "$BASE_DADA2/$GRUPO/denoising-stats.qzv" "$RESULTS_DIR/denoising-stats-${GRUPO}.qzv"
  fi
done

find "$COMBINED_OUT/results" -name "*.qzv" -exec cp {} "$RESULTS_DIR/" \; 2>/dev/null || true

NUM_QZV=$(ls -1 "$RESULTS_DIR"/*.qzv 2>/dev/null | wc -l)
echo "  ✓ $NUM_QZV visualizaciones copiadas"
echo ""

echo "=========================================="
echo "✓ PIPELINE OPTIMIZADO COMPLETADO"
echo "=========================================="
echo ""
echo "OPTIMIZACIONES APLICADAS:"
echo "-------------------------"
echo "✓ Procesamiento paralelo de muestras con GNU Parallel"
echo "✓ Compresión/descompresión paralela con pigz"
echo "✓ Construcción paralela de árboles filogenéticos"
echo "✓ Uso de tmpfs para archivos temporales"
echo ""
echo "Resultados en: $RESULTS_DIR"
echo "=========================================="
