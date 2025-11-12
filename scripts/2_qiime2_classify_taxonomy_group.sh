#!/usr/bin/env bash
# Clasificación taxonómica con SILVA para cada grupo por separado

set -euo pipefail
source /opt/conda/etc/profile.d/conda.sh
conda activate qiime2

CLASSIFIER="/home/proyecto/qiime2_results/taxonomy/silva-138-99-nb-classifier.qza"
BASE_DADA2="/home/proyecto/qiime2_results/dada2"
OUT_TAX="/home/proyecto/qiime2_results/taxonomy"
NJOBS=12

for GRUPO in Colitis Crohn Control; do
  echo "Clasificando taxonomía para $GRUPO"
  mkdir -p "$OUT_TAX/$GRUPO"

  # Clasificación taxonómica
  qiime feature-classifier classify-sklearn \
    --i-classifier "$CLASSIFIER" \
    --i-reads "$BASE_DADA2/$GRUPO/rep-seqs.qza" \
    --p-n-jobs $NJOBS \
    --p-confidence 0.7 \
    --o-classification "$OUT_TAX/$GRUPO/taxonomy.qza"

  # Visualización taxonómica
  qiime metadata tabulate \
    --m-input-file "$OUT_TAX/$GRUPO/taxonomy.qza" \
    --o-visualization "$OUT_TAX/$GRUPO/taxonomy.qzv"

  echo "Clasificación completada y visualizada: $OUT_TAX/$GRUPO/taxonomy.qzv"
done

conda deactivate