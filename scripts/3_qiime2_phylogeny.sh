#!/usr/bin/env bash
# Construcción de árboles filogenéticos por grupo (Colitis, Crohn, Control)

set -euo pipefail
source /opt/conda/etc/profile.d/conda.sh
conda activate qiime2

BASE_DADA2="/home/proyecto/qiime2_results/dada2"
OUT_PHYLO="/home/proyecto/qiime2_results/phylogeny"

for GRUPO in Colitis Crohn Control; do
  echo "Construyendo árbol filogenético para $GRUPO"
  GRUPO_OUT="$OUT_PHYLO/$GRUPO"
  mkdir -p "$GRUPO_OUT"

  qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences "$BASE_DADA2/$GRUPO/rep-seqs.qza" \
    --p-n-threads 12 \
    --o-alignment "$GRUPO_OUT/aligned-rep-seqs.qza" \
    --o-masked-alignment "$GRUPO_OUT/masked-aligned-rep-seqs.qza" \
    --o-tree "$GRUPO_OUT/unrooted-tree.qza" \
    --o-rooted-tree "$GRUPO_OUT/rooted-tree.qza"

  echo "Árbol generado para $GRUPO: $GRUPO_OUT"
done

conda deactivate