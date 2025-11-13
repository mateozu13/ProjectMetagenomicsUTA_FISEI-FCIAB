#!/usr/bin/env bash
# Clasificación taxonómica con SILVA para cada grupo por separado

set -euo pipefail
source /opt/conda/etc/profile.d/conda.sh
conda activate qiime2

CLASSIFIER="/home/proyecto/qiime2_results/taxonomy/silva-138-99-nb-classifier.qza"
BASE_DADA2="/home/proyecto/qiime2_results/dada2"
OUT_TAX="/home/proyecto/qiime2_results/taxonomy"
NJOBS=6 # probar con 8 - 10 
# con 12 nucleos no funciona por el consumo total de RAM

# Verificar que el clasificador exista
if [[ ! -f "$CLASSIFIER" ]]; then
  echo "[ERROR] Clasificador no encontrado: $CLASSIFIER"
  exit 1
fi

for GRUPO in Colitis Crohn Control; do
  echo "[INFO] Clasificando taxonomía para $GRUPO"
  mkdir -p "$OUT_TAX/$GRUPO"

  REP_SEQS="$BASE_DADA2/$GRUPO/rep-seqs.qza"
  OUT_TAXON="$OUT_TAX/$GRUPO/taxonomy.qza"
  OUT_TAXON_VIZ="$OUT_TAX/$GRUPO/taxonomy.qzv"

  if [[ ! -f "$REP_SEQS" ]]; then
    echo "[WARNING] No se encontró: $REP_SEQS – omitiendo $GRUPO"
    continue
  fi

  # Clasificación taxonómica
  qiime feature-classifier classify-sklearn \
    --i-classifier "$CLASSIFIER" \
    --i-reads "$REP_SEQS" \
    --p-n-jobs "$NJOBS" \
    --p-confidence 0.7 \
    --o-classification "$OUT_TAXON"

  # Visualización taxonómica
  qiime metadata tabulate \
    --m-input-file "$OUT_TAXON" \
    --o-visualization "$OUT_TAXON_VIZ"

  echo "[OK] Clasificación completada y visualización generada: $OUT_TAXON_VIZ"
done

conda deactivate
