#!/bin/bash
# Script para procesar secuencias 16S con QIIME2 para los grupos Colitis, Crohn y Control.
# Asegurarse de activar el entorno conda 'qiime2' antes de ejecutar este script.

# Validación de comandos necesarios
if ! command -v qiime &>/dev/null; then
  echo "Error: QIIME2 no está disponible. Active el entorno conda 'qiime2' antes de ejecutar." >&2
  exit 1
fi
if ! command -v biom &>/dev/null; then
  echo "Error: La herramienta 'biom' no está instalada o no está en el PATH. Verifique la instalación de QIIME2." >&2
  exit 1
fi

# Definir directorios base de entrada y salida
BASE_INPUT="/home/proyecto/preproc"
BASE_OUTPUT="/home/proyecto/qiime2_results"
threads=12

# Verificar existencia del clasificador taxonómico pre-entrenado
CLASSIFIER_PATH="$BASE_OUTPUT/taxonomy/silva-138-99-nb-classifier.qza"
if [ ! -f "$CLASSIFIER_PATH" ]; then
  echo "Error: No se encontró el clasificador taxonómico en $CLASSIFIER_PATH" >&2
  exit 1
fi

# Grupos experimentales a procesar
groups=("Colitis" "Crohn" "Control")

# Bucle principal por cada grupo
for GROUP in "${groups[@]}"; do
  echo "=== Procesando grupo: $GROUP ==="
  INPUT_DIR="$BASE_INPUT/$GROUP"
  
  # Validar directorio de entrada
  if [ ! -d "$INPUT_DIR" ]; then
    echo "ADVERTENCIA: No se encontró el directorio $INPUT_DIR. Se omite el grupo $GROUP." >&2
    continue
  fi
  
  # Buscar archivos FASTQ forward en el directorio del grupo
  shopt -s nullglob
  fwd_files=("$INPUT_DIR"/*_filtered_1.fq.gz)
  shopt -u nullglob
  if [ ${#fwd_files[@]} -eq 0 ]; then
    echo "ADVERTENCIA: No hay archivos '*_filtered_1.fq.gz' en $INPUT_DIR. Se omite el grupo $GROUP." >&2
    continue
  fi
  
  # Crear directorios de resultados para cada proceso de este grupo
  mkdir -p "$BASE_OUTPUT/manifest/$GROUP" \
           "$BASE_OUTPUT/import/$GROUP" \
           "$BASE_OUTPUT/dada2/$GROUP" \
           "$BASE_OUTPUT/taxonomy/$GROUP" \
           "$BASE_OUTPUT/phylogeny/$GROUP" \
           "$BASE_OUTPUT/core_metrics/$GROUP"
  
  # a. Crear archivo manifest.tsv para el grupo
  MANIFEST_PATH="$BASE_OUTPUT/manifest/$GROUP/manifest_${GROUP}.tsv"
  echo "Creando manifest: $MANIFEST_PATH"
  printf "sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n" > "$MANIFEST_PATH"
  for fwd in "${fwd_files[@]}"; do
    sample_id=$(basename "$fwd" "_filtered_1.fq.gz")
    rev="$INPUT_DIR/${sample_id}_filtered_2.fq.gz"
    if [ ! -f "$rev" ]; then
      echo "ADVERTENCIA: No se encontró el archivo reverse para ${sample_id}, muestra omitida." >&2
      continue
    fi
    printf "%s\t%s\t%s\n" "$sample_id" "$fwd" "$rev" >> "$MANIFEST_PATH"
  done
  
  # b. Importar secuencias emparejadas como artefacto QIIME2 (.qza)
  IMPORT_QZA="$BASE_OUTPUT/import/$GROUP/demux-${GROUP}.qza"
  echo "Importando secuencias de $GROUP a $IMPORT_QZA"
  qiime tools import \
    --type 'SampleData[PairedEndSequencesWithQuality]' \
    --input-path "$MANIFEST_PATH" \
    --output-path "$IMPORT_QZA" \
    --input-format PairedEndFastqManifestPhred33V2
  
  # c. Denoise con DADA2 para obtener tabla de características y secuencias representativas
  TABLE_QZA="$BASE_OUTPUT/dada2/$GROUP/table-${GROUP}.qza"
  REPSEQS_QZA="$BASE_OUTPUT/dada2/$GROUP/rep-seqs-${GROUP}.qza"
  STATS_QZA="$BASE_OUTPUT/dada2/$GROUP/stats-dada2-${GROUP}.qza"
  echo "Ejecutando DADA2 denoise-paired para $GROUP (puede tardar varios minutos)..."
  qiime dada2 denoise-paired \
    --i-demultiplexed-seqs "$IMPORT_QZA" \
    --p-trunc-len-f 230 \
    --p-trunc-len-r 220 \
    --p-trim-left-f 0 \
    --p-trim-left-r 0 \
    --p-max-ee-f 4.0 \
    --p-max-ee-r 4.0 \
    --p-n-threads $threads \
    --o-table "$TABLE_QZA" \
    --o-representative-sequences "$REPSEQS_QZA" \
    --o-denoising-stats "$STATS_QZA"

  # visualización denoising-stats
  # qiime metadata tabulate \
  #   --m-input-file denoising-stats.qza \
  #   --o-visualization denoising-stats.qzv

  
  # d. Clasificación taxonómica de secuencias representativas con el clasificador pre-entrenado
  TAXONOMY_QZA="$BASE_OUTPUT/taxonomy/$GROUP/taxonomy-${GROUP}.qza"
  echo "Clasificando taxonómicamente secuencias de $GROUP..."
  qiime feature-classifier classify-sklearn \
    --i-reads "$REPSEQS_QZA" \
    --i-classifier "$CLASSIFIER_PATH" \
    --o-classification "$TAXONOMY_QZA"
  
  # e. Generar visualización de la clasificación taxonómica (gráfico de barras por taxa)
  TAXA_BARPLOT_QZV="$BASE_OUTPUT/taxonomy/$GROUP/taxa-barplot-${GROUP}.qzv"
  echo "Generando gráfico de barras taxonómico: $TAXA_BARPLOT_QZV"
  qiime taxa barplot \
    --i-table "$TABLE_QZA" \
    --i-taxonomy "$TAXONOMY_QZA" \
    --m-metadata-file /home/proyecto/metadata.tsv \
    --o-visualization "$TAXA_BARPLOT_QZV"
  
  # f. Construir árbol filogenético a partir de las secuencias representativas
  ALIGNED_QZA="$BASE_OUTPUT/phylogeny/$GROUP/aligned-rep-seqs-${GROUP}.qza"
  MASKED_QZA="$BASE_OUTPUT/phylogeny/$GROUP/masked-aligned-rep-seqs-${GROUP}.qza"
  UNROOTED_QZA="$BASE_OUTPUT/phylogeny/$GROUP/unrooted-tree-${GROUP}.qza"
  ROOTED_QZA="$BASE_OUTPUT/phylogeny/$GROUP/rooted-tree-${GROUP}.qza"
  echo "Construyendo árbol filogenético para $GROUP..."
  qiime phylogeny align-to-tree-mafft-fasttree \
    --i-sequences "$REPSEQS_QZA" \
    --o-alignment "$ALIGNED_QZA" \
    --o-masked-alignment "$MASKED_QZA" \
    --o-tree "$UNROOTED_QZA" \
    --o-rooted-tree "$ROOTED_QZA" \
    --p-n-threads $threads
  
  # g. Calcular métricas de diversidad central (alpha y beta) con rarefacción
  CORE_DIR="$BASE_OUTPUT/core_metrics/$GROUP"
  FILTERED_TABLE_QZA="$CORE_DIR/table-nozero-${GROUP}.qza"
  echo "Filtrando muestras sin lecturas (si las hay) y determinando profundidad de muestreo para $GROUP..."
  # Filtrar muestras con frecuencia < 1 (elimina muestras vacías)
  qiime feature-table filter-samples \
    --i-table "$TABLE_QZA" \
    --p-min-frequency 1 \
    --o-filtered-table "$FILTERED_TABLE_QZA"
  # Exportar tabla filtrada a BIOM y calcular el mínimo > 0
  TMP_DIR=$(mktemp -d)
  qiime tools export --input-path "$FILTERED_TABLE_QZA" --output-path "$TMP_DIR"
  BIOM_FILE="$TMP_DIR/feature-table.biom"
  if [ ! -f "$BIOM_FILE" ]; then
    BIOM_FILE=$(find "$TMP_DIR" -type f -name "*.biom" -print -quit)
  fi
  MIN_FREQ=$(biom summarize-table -i "$BIOM_FILE" 2>/dev/null | \
             grep -A1 "Counts/sample summary:" | tail -n1 | sed 's/,//g; s/.*Min:\s*//; s/\..*//')
  rm -rf "$TMP_DIR"
  if [[ -z "$MIN_FREQ" || "$MIN_FREQ" -lt 1 ]]; then
    echo "ADVERTENCIA: No se pudo determinar una profundidad de muestreo válida (>0) para $GROUP. Se omite core-metrics." >&2
    continue
  fi
  echo "Profundidad de muestreo seleccionada para $GROUP: $MIN_FREQ secuencias por muestra."
  # Ejecutar core-metrics-phylogenetic con la profundidad determinada
  TMP_CORE_DIR=$(mktemp -d)
  qiime diversity core-metrics-phylogenetic \
    --i-phylogeny "$ROOTED_QZA" \
    --i-table "$FILTERED_TABLE_QZA" \
    --p-sampling-depth "$MIN_FREQ" \
    --m-metadata-file /home/proyecto/metadata.tsv \
    --output-dir "$TMP_CORE_DIR"
  # Mover todos los resultados generados al directorio final de core_metrics del grupo
  mv "$TMP_CORE_DIR"/* "$CORE_DIR"/
  rmdir "$TMP_CORE_DIR"
  
  # h. Generar visualizaciones de significancia alpha y beta diversity por grupo
  ALPHA_GROUP_QZV="$CORE_DIR/alpha-group-significance-${GROUP}.qzv"
  BETA_GROUP_QZV="$CORE_DIR/beta-group-significance-${GROUP}.qzv"
  echo "Evaluando significancia de diversidad alpha (Faith PD) para $GROUP..."
  qiime diversity alpha-group-significance \
    --i-alpha-diversity "$CORE_DIR/faith_pd_vector.qza" \
    --m-metadata-file /home/proyecto/metadata.tsv \
    --o-visualization "$ALPHA_GROUP_QZV"
  echo "Evaluando significancia de diversidad beta (UniFrac unweighted) para $GROUP..."
  qiime diversity beta-group-significance \
    --i-distance-matrix "$CORE_DIR/unweighted_unifrac_distance_matrix.qza" \
    --m-metadata-file /home/proyecto/metadata.tsv \
    --m-metadata-column Group \
    --p-pairwise \
    --o-visualization "$BETA_GROUP_QZV"
  
  echo "Procesamiento del grupo $GROUP completado."
done

echo "¡Análisis finalizado! Los resultados se encuentran en $BASE_OUTPUT/{proceso}/{Grupo}/"
