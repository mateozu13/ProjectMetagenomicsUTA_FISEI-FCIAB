#!/usr/bin/env bash
# Script para análisis de diversidad COMPARATIVO entre todos los grupos

export TMPDIR="/mnt/qiime2_tmp"

set -euo pipefail
source /opt/conda/etc/profile.d/conda.sh
conda activate qiime2

METADATA="/home/proyecto/metadata.tsv"
BASE_DADA2="/home/proyecto/qiime2_results/dada2"
BASE_PHYLO="/home/proyecto/qiime2_results/phylogeny"
OUT_DIV="/home/proyecto/qiime2_results/core_diversity"
SAMPLING_DEPTH=6000

echo ""
echo "=========================================="
echo "Análisis COMPARATIVO entre todos los grupos"
echo "=========================================="

# Directorio de salida para análisis combinado
COMBINED_OUT="$OUT_DIV/combined_analysis"

# Eliminar resultados previos si existen
if [[ -d "$COMBINED_OUT" ]]; then
  echo "Eliminando resultados previos en $COMBINED_OUT"
  rm -rf "$COMBINED_OUT"
fi
mkdir -p "$COMBINED_OUT"

# ============================================
# PASO 1: Combinar las tablas de los 3 grupos
# ============================================
echo ""
echo "PASO 1: Combinando tablas de feature de todos los grupos..."

qiime feature-table merge \
  --i-tables "$BASE_DADA2/Colitis/table.qza" \
  --i-tables "$BASE_DADA2/Crohn/table.qza" \
  --i-tables "$BASE_DADA2/Control/table.qza" \
  --o-merged-table "$COMBINED_OUT/merged_table.qza"

if [[ $? -ne 0 ]]; then
  echo "ERROR: No se pudo combinar las tablas"
  exit 1
fi

# ============================================
# PASO 2: Combinar las secuencias representativas
# ============================================
echo ""
echo "PASO 2: Combinando secuencias representativas..."

qiime feature-table merge-seqs \
  --i-data "$BASE_DADA2/Colitis/rep-seqs.qza" \
  --i-data "$BASE_DADA2/Crohn/rep-seqs.qza" \
  --i-data "$BASE_DADA2/Control/rep-seqs.qza" \
  --o-merged-data "$COMBINED_OUT/merged_rep-seqs.qza"

if [[ $? -ne 0 ]]; then
  echo "ERROR: No se pudo combinar las secuencias"
  exit 1
fi

# ============================================
# PASO 3: Generar árbol filogenético combinado
# ============================================
echo ""
echo "PASO 3: Generando árbol filogenético para datos combinados..."

# Alineamiento
qiime phylogeny align-to-tree-mafft-fasttree \
  --i-sequences "$COMBINED_OUT/merged_rep-seqs.qza" \
  --o-alignment "$COMBINED_OUT/aligned-rep-seqs.qza" \
  --o-masked-alignment "$COMBINED_OUT/masked-aligned-rep-seqs.qza" \
  --o-tree "$COMBINED_OUT/unrooted-tree.qza" \
  --o-rooted-tree "$COMBINED_OUT/rooted-tree.qza"

if [[ $? -ne 0 ]]; then
  echo "ERROR: No se pudo generar el árbol filogenético"
  exit 1
fi

# ============================================
# PASO 4: Core metrics con datos combinados
# ============================================
echo ""
echo "PASO 4: Ejecutando core-metrics-phylogenetic con datos combinados..."

qiime diversity core-metrics-phylogenetic \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA" \
  --p-sampling-depth $SAMPLING_DEPTH \
  --output-dir "$COMBINED_OUT/results"

if [[ $? -ne 0 ]]; then
  echo "ERROR: core-metrics-phylogenetic falló"
  exit 1
fi

# ============================================
# PASO 5: Análisis de significancia ALFA
# ============================================
echo ""
echo "PASO 5: Análisis de significancia de alfa diversidad..."

for metric in shannon evenness faith_pd observed_features; do
  if [[ -f "$COMBINED_OUT/results/${metric}_vector.qza" ]]; then
    echo "  Procesando métrica: $metric"
    qiime diversity alpha-group-significance \
      --i-alpha-diversity "$COMBINED_OUT/results/${metric}_vector.qza" \
      --m-metadata-file "$METADATA" \
      --o-visualization "$COMBINED_OUT/results/${metric}-group-significance.qzv"
    
    if [[ $? -ne 0 ]]; then
      echo "  ADVERTENCIA: alpha-group-significance falló para $metric"
    fi
  else
    echo "  ADVERTENCIA: No se encontró ${metric}_vector.qza"
  fi
done

# ============================================
# PASO 6: Análisis de significancia BETA
# ============================================
echo ""
echo "PASO 6: Análisis de significancia de beta diversidad..."

# Unweighted UniFrac
if [[ -f "$COMBINED_OUT/results/unweighted_unifrac_distance_matrix.qza" ]]; then
  echo "  Procesando Unweighted UniFrac..."
  qiime diversity beta-group-significance \
    --i-distance-matrix "$COMBINED_OUT/results/unweighted_unifrac_distance_matrix.qza" \
    --m-metadata-file "$METADATA" \
    --m-metadata-column Group \
    --o-visualization "$COMBINED_OUT/results/unweighted-unifrac-group-significance.qzv" \
    --p-pairwise
  
  if [[ $? -ne 0 ]]; then
    echo "  ADVERTENCIA: beta-group-significance falló para Unweighted UniFrac"
  fi
fi

# Weighted UniFrac
if [[ -f "$COMBINED_OUT/results/weighted_unifrac_distance_matrix.qza" ]]; then
  echo "  Procesando Weighted UniFrac..."
  qiime diversity beta-group-significance \
    --i-distance-matrix "$COMBINED_OUT/results/weighted_unifrac_distance_matrix.qza" \
    --m-metadata-file "$METADATA" \
    --m-metadata-column Group \
    --o-visualization "$COMBINED_OUT/results/weighted-unifrac-group-significance.qzv" \
    --p-pairwise
  
  if [[ $? -ne 0 ]]; then
    echo "  ADVERTENCIA: beta-group-significance falló para Weighted UniFrac"
  fi
fi

# Bray-Curtis
if [[ -f "$COMBINED_OUT/results/bray_curtis_distance_matrix.qza" ]]; then
  echo "  Procesando Bray-Curtis..."
  qiime diversity beta-group-significance \
    --i-distance-matrix "$COMBINED_OUT/results/bray_curtis_distance_matrix.qza" \
    --m-metadata-file "$METADATA" \
    --m-metadata-column Group \
    --o-visualization "$COMBINED_OUT/results/bray-curtis-group-significance.qzv" \
    --p-pairwise
  
  if [[ $? -ne 0 ]]; then
    echo "  ADVERTENCIA: beta-group-significance falló para Bray-Curtis"
  fi
fi

# Jaccard
if [[ -f "$COMBINED_OUT/results/jaccard_distance_matrix.qza" ]]; then
  echo "  Procesando Jaccard..."
  qiime diversity beta-group-significance \
    --i-distance-matrix "$COMBINED_OUT/results/jaccard_distance_matrix.qza" \
    --m-metadata-file "$METADATA" \
    --m-metadata-column Group \
    --o-visualization "$COMBINED_OUT/results/jaccard-group-significance.qzv" \
    --p-pairwise
  
  if [[ $? -ne 0 ]]; then
    echo "  ADVERTENCIA: beta-group-significance falló para Jaccard"
  fi
fi

# ============================================
# PASO 7: Rarefacción alfa con datos combinados
# ============================================
echo ""
echo "PASO 7: Curvas de rarefacción con datos combinados..."

qiime diversity alpha-rarefaction \
  --i-table "$COMBINED_OUT/merged_table.qza" \
  --i-phylogeny "$COMBINED_OUT/rooted-tree.qza" \
  --m-metadata-file "$METADATA" \
  --p-max-depth $SAMPLING_DEPTH \
  --o-visualization "$COMBINED_OUT/results/alpha-rarefaction.qzv"

if [[ $? -ne 0 ]]; then
  echo "ADVERTENCIA: alpha-rarefaction falló"
fi

conda deactivate

echo ""
echo "=========================================="
echo "✓ Análisis comparativo completado"
echo "=========================================="
echo "Resultados en: $COMBINED_OUT/results"
echo ""
echo "Archivos importantes generados:"
echo "  - merged_table.qza: Tabla combinada de todos los grupos"
echo "  - rooted-tree.qza: Árbol filogenético combinado"
echo "  - *-group-significance.qzv: Comparaciones estadísticas entre grupos"
echo "  - *_emperor.qzv: Visualizaciones PCoA interactivas"
echo ""