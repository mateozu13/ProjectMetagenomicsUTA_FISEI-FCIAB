#!/bin/bash
# Preprocesamiento con fastp usando 12 hilos, con resumen MultiQC

set -euo pipefail

# Directorios
raw_dir="/home/proyecto/Secuencias Crudas"
out_dir="/home/proyecto/preproc"
threads=12

# Crear directorios de salida por grupo si no existen
mkdir -p "$out_dir"/Colitis "$out_dir"/Crohn "$out_dir"/Control

# Iterar por todos los archivos *_1.fq.gz (R1)
find "$raw_dir" -type f -name "*_1.fq.gz" | while read -r R1; do
    group=$(basename "$(dirname "$R1")")  # Crohn / Colitis / Control
    sample=$(basename "$R1" "_1.fq.gz")
    R2="${R1/_1.fq.gz/_2.fq.gz}"

    # Validar existencia del R2
    if [[ ! -f "$R2" ]]; then
        echo "[ADVERTENCIA] No se encontró R2 para $sample, se omite."
        continue
    fi

    # Archivos de salida
    out_f1="$out_dir/$group/${sample}_filtered_1.fq.gz"
    out_f2="$out_dir/$group/${sample}_filtered_2.fq.gz"
    html="$out_dir/$group/${sample}_fastp.html"
    json="$out_dir/$group/${sample}_fastp.json"
    log="$out_dir/$group/${sample}_fastp.log"

    echo "[INFO] Procesando muestra: $sample (grupo: $group)"

    fastp \
        --in1 "$R1" --in2 "$R2" \
        --out1 "$out_f1" --out2 "$out_f2" \
        --detect_adapter_for_pe \
        --trim_front1 10 --trim_front2 10 \
        --cut_tail \
        --qualified_quality_phred 20 \
        --length_required 150 \
        --thread $threads \
        --html "$html" \
        --json "$json" \
        --report_title "$sample Fastp Report" \
        --dont_overwrite \
        &> "$log"
done

# Análisis unificado con MultiQC
echo "[INFO] Ejecutando MultiQC sobre resultados de fastp…"
multiqc "$out_dir" -o "$out_dir/multiqc_report"

echo "[FINALIZADO] Todas las muestras fueron procesadas y el resumen está en:"
echo "  $out_dir/multiqc_report"
