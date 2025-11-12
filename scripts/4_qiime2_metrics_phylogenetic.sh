#!/usr/bin/env bash
# Script para análisis de diversidad + visualizaciones por grupo en Qiime2

set -euo pipefail
source /opt/conda/etc/profile.d/conda.sh
conda activate qiime2

METADATA="/home/proyecto/metadata.tsv"
BASE_DADA2="/home/proyecto/qiime2_results/dada2"
BASE_PHYLO="/home/proyecto/qiime2_results/phylogeny"
OUT_DIV="/home/proyecto/qiime2_results/core_diversity"
SAMPLING_DEPTH=5000

for GRUPO in Colitis Crohn Control; do
  echo "Ejecutando análisis de diversidad para $GRUPO"

  GRUPO_OUT="$OUT_DIV/$GRUPO"

  # Eliminar resultados previos si existen
  if [[ -d "$GRUPO_OUT" ]]; then
    echo "Eliminando resultados previos en $GRUPO_OUT"
    rm -rf "$GRUPO_OUT"
  fi

  # Core metrics
  qiime diversity core-metrics-phylogenetic \
    --i-table "$BASE_DADA2/$GRUPO/table.qza" \
    --i-phylogeny "$BASE_PHYLO/$GRUPO/rooted-tree.qza" \
    --m-metadata-file "$METADATA" \
    --p-sampling-depth $SAMPLING_DEPTH \
    --output-dir "$GRUPO_OUT"

  # Rarefacción alfa
  qiime diversity alpha-rarefaction \
    --i-table "$GRUPO_OUT/rarefied_table.qza" \
    --i-phylogeny "$GRUPO_OUT/rooted-tree.qza" \
    --m-metadata-file "$METADATA" \
    --o-visualization "$GRUPO_OUT/alpha-rarefaction.qzv"

  # Significancia de alfa diversidad
  for metric in shannon evenness faith_pd observed_features; do
    if [[ -f "$GRUPO_OUT/${metric}_vector.qza" ]]; then
      qiime diversity alpha-group-significance \
        --i-alpha-diversity "$GRUPO_OUT/${metric}_vector.qza" \
        --m-metadata-file "$METADATA" \
        --o-visualization "$GRUPO_OUT/${metric}-group-significance.qzv"
    fi
  done

  # Significancia de beta diversidad
  if [[ -f "$GRUPO_OUT/unweighted_unifrac_distance_matrix.qza" ]]; then
    qiime diversity beta-group-significance \
      --i-distance-matrix "$GRUPO_OUT/unweighted_unifrac_distance_matrix.qza" \
      --m-metadata-file "$METADATA" \
      --m-metadata-column Group \
      --o-visualization "$GRUPO_OUT/unweighted-unifrac-group-significance.qzv" \
      --p-pairwise
  fi

done

conda deactivate

echo -e "\nCore metrics y visualizaciones completadas por grupo."