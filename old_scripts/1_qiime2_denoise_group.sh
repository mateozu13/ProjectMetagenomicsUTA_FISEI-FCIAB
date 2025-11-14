#!/usr/bin/env bash
# Script general para ejecutar DADA2 por grupo experimental (Colitis, Crohn, Control)
# Cada grupo debe estar en: /home/proyecto/preproc/{Grupo}/
# Cada salida se almacena en: /home/proyecto/qiime2_results/dada2/{Grupo}/
# Usa entorno conda "qiime2"

export TMPDIR="/mnt/qiime2_tmp"

set -euo pipefail

# Variables comunes
BASE_INPUT=/home/proyecto/preproc
BASE_OUT=/home/proyecto/qiime2_results/dada2
TRIM_LEFT_F=0
TRIM_LEFT_R=0
TRUNC_LEN_F=230
TRUNC_LEN_R=220
THREADS=2
CONDA_BASE="/opt/conda/bin/conda"
CONDA="/opt/conda/bin/conda run -n qiime2"

# Activar entorno
source /opt/conda/etc/profile.d/conda.sh
$CONDA_BASE activate qiime2

# Función para procesar un grupo
denoise_grupo() {
  local GRUPO=$1
  local GRUPO_INPUT="$BASE_INPUT/$GRUPO"
  local GRUPO_OUT="$BASE_OUT/$GRUPO"
  local MANIFEST="$GRUPO_OUT/manifest.tsv"
  local DEMUX="$GRUPO_OUT/demux-paired.qza"

  echo -e "\nProcesando grupo: $GRUPO"
  mkdir -p "$GRUPO_OUT"

  # Crear manifest.tsv
  echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > "$MANIFEST"
  for f in "$GRUPO_INPUT"/*_filtered_1.fq.gz; do
    id=$(basename "$f" | cut -d '_' -f1-2)
    rev="${f/_filtered_1/_filtered_2}"
    echo -e "$id\t$f\t$rev" >> "$MANIFEST"
  done

  # Importar
  $CONDA qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST" \
    --output-path "$DEMUX" \
    --input-format PairedEndFastqManifestPhred33V2

  # Denoising
  $CONDA qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$DEMUX" \
    --p-trim-left-f $TRIM_LEFT_F \
    --p-trim-left-r $TRIM_LEFT_R \
    --p-trunc-len-f $TRUNC_LEN_F \
    --p-trunc-len-r $TRUNC_LEN_R \
    --p-max-ee-f 2.0 \
    --p-max-ee-r 2.0 \
    --p-n-threads $THREADS \
    --o-table "$GRUPO_OUT/table.qza" \
    --o-representative-sequences "$GRUPO_OUT/rep-seqs.qza" \
    --o-denoising-stats "$GRUPO_OUT/denoising-stats.qza"

  echo "Finalizado $GRUPO en: $GRUPO_OUT"
}

# Ejecutar por grupo
denoise_grupo "Colitis"
denoise_grupo "Crohn"
denoise_grupo "Control"

$CONDA_BASE deactivate

echo -e "\nTodos los grupos procesados con éxito!"
