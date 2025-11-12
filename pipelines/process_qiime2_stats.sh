#!/usr/bin/env bash

# ===================== CONFIGURACIÓN INICIAL ======================

# Habilitar "strict mode" opcionalmente:
set -o pipefail   # Propaga errores a través de pipes
#set -e           # (Opcional) Finaliza si ocurre un error no controlado

# Nombre del entorno conda de Qiime 2
CONDA_ENV="qiime2"

# Activar el entorno conda Qiime2 (asegúrese de que conda esté disponible)
# Si la shell no tiene conda inicializado, se puede source manualmente:
if [ -z "$CONDA_PREFIX" ] || [[ "$CONDA_DEFAULT_ENV" != "$CONDA_ENV" ]]; then
    # Cargar funciones de conda y activar entorno
    source "$(conda info --base)/etc/profile.d/conda.sh" 2>/dev/null
    conda activate "$CONDA_ENV"
fi

# Directorios base para resultados y logs (usar rutas absolutas si es necesario)
BASE_DIR="/home/proyecto"  # Por defecto, usa el directorio actual como base
RESULTS_DIR="$BASE_DIR/results"
LOGS_DIR="$BASE_DIR/logs"

# Crear los directorios base si no existen
mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

# Definir grupos experimentales a procesar
groups=("Colitis" "Crohn" "Control")

# ===================== FUNCIONES POR ETAPA ======================

# 1. Función para DADA2 (denoise + chimera removal) por grupo
run_dada2() {
    local GROUP="$1"
    echo "[$GROUP] Iniciando etapa DADA2..."
    # Directorio de resultados y logs para esta etapa
    local OUTDIR="$RESULTS_DIR/$GROUP/dada2"
    local LOGDIR="$LOGS_DIR/$GROUP/dada2"
    mkdir -p "$OUTDIR" "$LOGDIR"

    # Archivos de entrada y salida
    # Supongamos que existe un archivo de secuencias demultiplexadas .qza por grupo:
    local DEMUX_QZA="path/to/${GROUP}_demux.qza"   # <<== RUTA a input demultiplexado de este grupo
    local TABLE_QZA="$OUTDIR/table.qza"
    local REPS_QZA="$OUTDIR/rep-seqs.qza"
    local STATS_QZA="$OUTDIR/denoising-stats.qza"

    # Comprobar si la salida ya existe
    if [[ -f "$TABLE_QZA" && -f "$REPS_QZA" && -f "$STATS_QZA" ]]; then
        echo "[$GROUP] Salidas DADA2 ya existen, se omite esta etapa."
        return 0
    fi

    # Iniciar dstat en segundo plano (ej. CPU, memoria cada 1s)
    local DSTAT_CSV="$LOGDIR/dstat_${GROUP}_dada2.csv"
    dstat -Tcm --output "$DSTAT_CSV" 1 > /dev/null 2>&1 &
    local DSTAT_PID=$!

    # Ejecutar Qiime2 DADA2 con time -v. Usar 12 hilos (--p-n-threads 12).
    local CMD="qiime dada2 denoise-paired --i-demultiplexed-seqs $DEMUX_QZA \
        --p-trunc-len-f 0 --p-trunc-len-r 0 \  # (Ajustar parámetros de truncado según datos)
        --p-n-threads 12 \                    # Usa 12 núcleos (0 para usar todos disponibles) 
        --o-table $TABLE_QZA \
        --o-representative-sequences $REPS_QZA \
        --o-denoising-stats $STATS_QZA"
    # Ejecutar el comando y medir tiempo/recursos, redirigiendo salida y errores al log
    /usr/bin/time -v bash -c "$CMD" &> "$LOGDIR/${GROUP}_dada2.log"
    local STATUS=$?

    # Detener dstat
    kill $DSTAT_PID 2>/dev/null

    if [ $STATUS -ne 0 ]; then
        echo "[$GROUP] ERROR: Falló DADA2 (código $STATUS). Revisar log." | tee -a "$LOGDIR/${GROUP}_dada2.log"
        return $STATUS
    fi
    echo "[$GROUP] DADA2 completado correctamente."
    return 0
}

# 2. Función para clasificación taxonómica por grupo
run_taxonomy() {
    local GROUP="$1"
    echo "[$GROUP] Iniciando etapa de clasificación taxonómica..."
    local OUTDIR="$RESULTS_DIR/$GROUP/taxonomy"
    local LOGDIR="$LOGS_DIR/$GROUP/taxonomy"
    mkdir -p "$OUTDIR" "$LOGDIR"

    # Archivos de entrada (usa secuencias representativas de DADA2) y salida
    local REPS_QZA="$RESULTS_DIR/$GROUP/dada2/rep-seqs.qza"
    local CLASSIFIER_QZA="path/to/pretrained_classifier.qza"  # <<== Ruta al clasificador pre-entrenado (e.g. Silva, Greengenes)
    local TAXONOMY_QZA="$OUTDIR/taxonomy.qza"
    local TAXONOMY_QZV="$OUTDIR/taxonomy.qzv"

    if [[ -f "$TAXONOMY_QZA" ]]; then
        echo "[$GROUP] Salida taxonómica $TAXONOMY_QZA ya existe, se omite clasificación."
        return 0
    fi

    # Iniciar dstat
    local DSTAT_CSV="$LOGDIR/dstat_${GROUP}_taxonomy.csv"
    dstat -Tcm --output "$DSTAT_CSV" 1 > /dev/null 2>&1 &
    local DSTAT_PID=$!

    # Comando Qiime2 para clasificación (naive Bayes pre-entrenado)
    local CMD="qiime feature-classifier classify-sklearn --i-reads $REPS_QZA \
        --i-classifier $CLASSIFIER_QZA \
        --p-n-jobs 12 \   # Usa 12 procesos en paralelo para acelerar clasificación
        --o-classification $TAXONOMY_QZA"
    /usr/bin/time -v bash -c "$CMD" &> "$LOGDIR/${GROUP}_taxonomy.log"
    local STATUS=$?

    # Detener dstat
    kill $DSTAT_PID 2>/dev/null

    if [ $STATUS -ne 0 ]; then
        echo "[$GROUP] ERROR: Falló clasificación taxonómica (código $STATUS). Revisar log." | tee -a "$LOGDIR/${GROUP}_taxonomy.log"
        return $STATUS
    fi

    # Generar visualización de la tabla taxonómica (opcional)
    qiime metadata tabulate --m-input-file "$TAXONOMY_QZA" --o-visualization "$TAXONOMY_QZV" 2>> "$LOGDIR/${GROUP}_taxonomy.log"
    echo "[$GROUP] Clasificación taxonómica completada."
    return 0
}

# 3. Función para construir árboles filogenéticos por grupo
run_phylogeny() {
    local GROUP="$1"
    echo "[$GROUP] Iniciando etapa de filogenia..."
    local OUTDIR="$RESULTS_DIR/$GROUP/phylogeny"
    local LOGDIR="$LOGS_DIR/$GROUP/phylogeny"
    mkdir -p "$OUTDIR" "$LOGDIR"

    # Entradas (secuencias rep.) y salidas (árboles)
    local REPS_QZA="$RESULTS_DIR/$GROUP/dada2/rep-seqs.qza"
    local ALIGNED_QZA="$OUTDIR/aligned-rep-seqs.qza"
    local MASKED_QZA="$OUTDIR/masked-aligned-rep-seqs.qza"
    local TREE_QZA="$OUTDIR/unrooted-tree.qza"
    local ROOTED_QZA="$OUTDIR/rooted-tree.qza"

    if [[ -f "$ROOTED_QZA" ]]; then
        echo "[$GROUP] Árbol filogenético ya existe ($ROOTED_QZA), se omite esta etapa."
        return 0
    fi

    # Iniciar dstat
    local DSTAT_CSV="$LOGDIR/dstat_${GROUP}_phylogeny.csv"
    dstat -Tcm --output "$DSTAT_CSV" 1 > /dev/null 2>&1 &
    local DSTAT_PID=$!

    # Comando Qiime2 para alineamiento MAFFT y árbol FastTree (pipeline integrado)
    local CMD="qiime phylogeny align-to-tree-mafft-fasttree --i-sequences $REPS_QZA \
        --p-n-threads 12 \        # Usa 12 hilos para MAFFT y FastTree (o 'auto' para todos):contentReference[oaicite:7]{index=7}
        --o-alignment $ALIGNED_QZA \
        --o-masked-alignment $MASKED_QZA \
        --o-tree $TREE_QZA \
        --o-rooted-tree $ROOTED_QZA"
    /usr/bin/time -v bash -c "$CMD" &> "$LOGDIR/${GROUP}_phylogeny.log"
    local STATUS=$?

    kill $DSTAT_PID 2>/dev/null

    if [ $STATUS -ne 0 ]; then
        echo "[$GROUP] ERROR: Falló generación de árbol (código $STATUS). Revisar log." | tee -a "$LOGDIR/${GROUP}_phylogeny.log"
        return $STATUS
    fi
    echo "[$GROUP] Árbol filogenético generado correctamente."
    return 0
}

# 4. Función para análisis de diversidad (alpha/beta) por grupo
run_diversity() {
    local GROUP="$1"
    echo "[$GROUP] Iniciando etapa de diversidad (core metrics)..."
    local OUTDIR="$RESULTS_DIR/$GROUP/diversity"
    local LOGDIR="$LOGS_DIR/$GROUP/diversity"
    mkdir -p "$OUTDIR" "$LOGDIR"

    # Entradas (tabla de frecuencias, árbol) y directorio de salida
    local TABLE_QZA="$RESULTS_DIR/$GROUP/dada2/table.qza"
    local ROOTED_QZA="$RESULTS_DIR/$GROUP/phylogeny/rooted-tree.qza"
    local METADATA="path/to/metadata.tsv"  # <<== Ruta a metadata de muestras (contiene info de grupo)
    local CORE_DIR="$OUTDIR/core_metrics_results"

    if [[ -d "$CORE_DIR" ]]; then
        echo "[$GROUP] Resultados de diversidad ya existen en $CORE_DIR, se omite esta etapa."
        return 0
    fi

    # Iniciar dstat
    local DSTAT_CSV="$LOGDIR/dstat_${GROUP}_diversity.csv"
    dstat -Tcm --output "$DSTAT_CSV" 1 > /dev/null 2>&1 &
    local DSTAT_PID=$!

    # Comando Qiime2 core-metrics-phylogenetic (métricas de diversidad)
    local CMD="qiime diversity core-metrics-phylogenetic --i-phylogeny $ROOTED_QZA \
        --i-table $TABLE_QZA \
        --p-sampling-depth 1000 \   # (Ejemplo de rarefacción; ajustar según datos)
        --m-metadata-file $METADATA \
        --p-n-jobs 12 \             # Usa 12 jobs para paralelizar cálculos internos:contentReference[oaicite:8]{index=8}
        --output-dir $CORE_DIR"
    /usr/bin/time -v bash -c "$CMD" &> "$LOGDIR/${GROUP}_diversity.log"
    local STATUS=$?

    kill $DSTAT_PID 2>/dev/null

    if [ $STATUS -ne 0 ]; then
        echo "[$GROUP] ERROR: Falló core-metrics (código $STATUS). Revisar log." | tee -a "$LOGDIR/${GROUP}_diversity.log"
        return $STATUS
    fi

    echo "[$GROUP] Métricas de diversidad calculadas (resultados en $CORE_DIR)."
    return 0
}

# ===================== EJECUCIÓN GENERAL ======================

# Parseo de argumentos para permitir ejecuciones parciales
# Uso esperado:
#   ./qiime_pipeline.sh              -> ejecuta todas las etapas para todos los grupos
#   ./qiime_pipeline.sh Colitis      -> ejecuta todas las etapas solo para Colitis
#   ./qiime_pipeline.sh dada2 Crohn  -> ejecuta solo etapa dada2 para Crohn (análogo para taxonomy, phylogeny, diversity)
#   ./qiime_pipeline.sh dada2 all    -> ejecuta solo etapa dada2 para todos los grupos
#
if [ $# -eq 0 ]; then
    # Sin argumentos: correr todo el pipeline para todos los grupos
    for group in "${groups[@]}"; do
        run_dada2 "$group"       || continue  # si falla, saltar al siguiente grupo
        run_taxonomy "$group"    || continue
        run_phylogeny "$group"   || continue
        run_diversity "$group"   || continue
    done
elif [[ " ${groups[*]} " == *" $1 "* ]]; then
    # Si el primer argumento es un nombre de grupo válido
    GROUP="$1"
    run_dada2 "$GROUP" && run_taxonomy "$GROUP" && run_phylogeny "$GROUP" && run_diversity "$GROUP"
elif [[ "$1" =~ ^(dada2|taxonomy|phylogeny|diversity)$ ]]; then
    # Si el primer argumento es un nombre de etapa
    STAGE="$1"
    if [ -z "$2" ] || [ "$2" == "all" ]; then
        # Ejecutar esa etapa para todos los grupos
        for group in "${groups[@]}"; do
            "run_${STAGE}" "$group"   # llama a la función run_dada2/taxonomy/etc dinámicamente
        done
    else
        # Ejecutar etapa para un grupo específico
        GROUP="$2"
        # Verificar que el grupo es válido
        if [[ " ${groups[*]} " != *" $GROUP "* ]]; then
            echo "Grupo '$GROUP' no reconocido. Grupos válidos: Colitis, Crohn, Control."
            exit 1
        fi
        "run_${STAGE}" "$GROUP"
    fi
else
    echo "Uso: $0 [<etapa> <grupo>|<grupo>]"
    echo "Etapas: dada2 | taxonomy | phylogeny | diversity"
    echo "Grupos: Colitis | Crohn | Control (o 'all' para todos los grupos)"
    exit 1
fi

echo "Pipeline completo."
