#!/usr/bin/env bash

set -euo pipefail

# ========= CONFIGURACIÓN =========
CONDA_ENV="qiime2"
PROJECT_DIR="/home/proyecto"
RAW_DIR="$PROJECT_DIR/preproc"
RESULTS_DIR="$PROJECT_DIR/qiime2_results"
LOGS_DIR="$PROJECT_DIR/logs"
CLASSIFIER="$PROJECT_DIR/qiime2_results/taxonomy/silva-138-99-nb-classifier.qza"
METADATA="$PROJECT_DIR/metadata.tsv"
THREADS=12
GROUPS=("Colitis" "Crohn" "Control")

# ========= CONDA ENV =========
if [ -z "${CONDA_PREFIX:-}" ] || [[ "$CONDA_DEFAULT_ENV" != "$CONDA_ENV" ]]; then
  source /opt/conda/etc/profile.d/conda.sh
  conda activate "$CONDA_ENV"
fi

# ========= FUNCIONES =========

import_sequences() {
  local group=$1
  local input_dir="$RAW_DIR/$group"
  local out_dir="$RESULTS_DIR/$group"
  local manifest="$out_dir/manifest.tsv"
  local demux="$out_dir/demux-paired.qza"

  mkdir -p "$out_dir"

  # Si ya existe el archivo importado, omitir
  [[ -f "$demux" ]] && return 0

  echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > "$manifest"
  for f in "$input_dir"/*_filtered_1.fq.gz; do
    id=$(basename "$f" | cut -d '_' -f1-2)
    r2="${f/_filtered_1/_filtered_2}"
    [[ -f "$r2" ]] && echo -e "$id\t$f\t$r2" >> "$manifest"
  done

  qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$manifest" \
    --output-path "$demux" \
    --input-format PairedEndFastqManifestPhred33V2
}

run_dada2() {
  local group=$1
  echo "[INFO] Procesando DADA2: $group"

  local group_dir="$RESULTS_DIR/$group"
  local dada2_dir="$group_dir/dada2"
  local log_dir="$LOGS_DIR/$group/dada2"
  mkdir -p "$dada2_dir" "$log_dir"

  import_sequences "$group"

  local cmd="
qiime dada2 denoise-paired \
  --i-demultiplexed-seqs $group_dir/demux-paired.qza \
  --p-trim-left-f 0 \
  --p-trim-left-r 0 \
  --p-trunc-len-f 230 \
  --p-trunc-len-r 220 \
  --p-n-threads $THREADS \
  --o-table $dada2_dir/table.qza \
  --o-representative-sequences $dada2_dir/rep-seqs.qza \
  --o-denoising-stats $dada2_dir/denoising-stats.qza"

  dstat -Tcm --output "$log_dir/dstat_dada2.csv" 1 > /dev/null 2>&1 &
  local dstat_pid=$!
  /usr/bin/time -v bash -c "$cmd" &> "$log_dir/run_dada2.log"
  kill $dstat_pid || true
}

run_taxonomy() {
  local group=$1
  echo "[INFO] Clasificando taxonomía: $group"

  local input="$RESULTS_DIR/$group/dada2/rep-seqs.qza"
  local out_dir="$RESULTS_DIR/$group/taxonomy"
  local log_dir="$LOGS_DIR/$group/taxonomy"
  mkdir -p "$out_dir" "$log_dir"

  dstat -Tcm --output "$log_dir/dstat_tax.csv" 1 > /dev/null 2>&1 &
  local dstat_pid=$!
  /usr/bin/time -v qiime feature-classifier classify-sklearn \
    --i-classifier "$CLASSIFIER" \
    --i-reads "$input" \
    --p-confidence 0.7 \
    --p-n-jobs $THREADS \
    --o-classification "$out_dir/taxonomy.qza" \
    &> "$log_dir/run_taxonomy.log"
  qiime metadata tabulate \
    --m-input-file "$out_dir/taxonomy.qza" \
    --o-visualization "$out_dir/taxonomy.qzv"
  kill $dstat_pid || true
}

run_phylogeny() {
  local group=$1
  echo "[INFO] Filogenia: $group"

  local input="$RESULTS_DIR/$group/dada2/rep-seqs.qza"
  local out_dir="$RESULTS_DIR/$group/phylogeny"
  local log_dir="$LOGS_DIR/$group/phylogeny"
  mkdir -p "$out_dir" "$log_dir"

  dstat -Tcm --output "$log_dir/dstat_phylogeny.csv" 1 > /dev/null 2>&1 &
  local dstat_pid=$!
  /usr/bin/time -v qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences "$input" \
    --p-n-threads $THREADS \
    --o-alignment "$out_dir/aligned-rep-seqs.qza" \
    --o-masked-alignment "$out_dir/masked-aligned-rep-seqs.qza" \
    --o-tree "$out_dir/unrooted-tree.qza" \
    --o-rooted-tree "$out_dir/rooted-tree.qza" \
    &> "$log_dir/run_phylogeny.log"
  kill $dstat_pid || true
}

run_diversity() {
  local group=$1
  echo "[INFO] Diversidad: $group"

  local table="$RESULTS_DIR/$group/dada2/table.qza"
  local tree="$RESULTS_DIR/$group/phylogeny/rooted-tree.qza"
  local out_dir="$RESULTS_DIR/$group/diversity"
  local log_dir="$LOGS_DIR/$group/diversity"
  mkdir -p "$out_dir" "$log_dir"

  dstat -Tcm --output "$log_dir/dstat_diversity.csv" 1 > /dev/null 2>&1 &
  local dstat_pid=$!
  /usr/bin/time -v qiime diversity core-metrics-phylogenetic \
    --i-table "$table" \
    --i-phylogeny "$tree" \
    --p-sampling-depth 1000 \
    --m-metadata-file "$METADATA" \
    --p-n-jobs $THREADS \
    --output-dir "$out_dir" \
    &> "$log_dir/run_diversity.log"
  kill $dstat_pid || true
}

# ========= EJECUCIÓN =========
for group in "${GROUPS[@]}"; do
  run_dada2 "$group"
  run_taxonomy "$group"
  run_phylogeny "$group"
  run_diversity "$group"
done

echo "[FINALIZADO] Pipeline completado para todos los grupos."
