#!/bin/bash
# Preprocesamiento con fastp usando 12 hilos y MultiQC por grupo

export TMPDIR="/mnt/qiime2_tmp"

set -euo pipefail

# Rutas
raw_dir="/home/proyecto/Secuencias Crudas"
out_dir="/home/proyecto/preproc"
threads=12

# Crear carpetas de salida
mkdir -p "$out_dir"/Colitis "$out_dir"/Crohn "$out_dir"/Control

# Leer archivos R1 en un array
mapfile -t R1_FILES < <(find "$raw_dir" -type f -name "*_1.fq.gz" | sort)

for R1 in "${R1_FILES[@]}"; do
    group=$(basename "$(dirname "$R1")")
    sample=$(basename "$R1" "_1.fq.gz")
    R2="${R1/_1.fq.gz/_2.fq.gz}"

    if [[ ! -f "$R2" ]]; then
        echo "[ADVERTENCIA] R2 faltante para $sample → se omite."
        continue
    fi

    out_f1="$out_dir/$group/${sample}_filtered_1.fq.gz"
    out_f2="$out_dir/$group/${sample}_filtered_2.fq.gz"
    html="$out_dir/$group/${sample}_fastp.html"
    json="$out_dir/$group/${sample}_fastp.json"
    log="$out_dir/$group/${sample}_fastp.log"

    echo "[INFO] Procesando muestra: $sample (grupo: $group)"

    /opt/conda/bin/conda run -n preproc fastp \
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
        &> "$log"
done

# MultiQC final
echo "[INFO] Ejecutando MultiQC sobre todos los resultados…"
multiqc "$out_dir" -o "$out_dir/multiqc_report"

echo "[FINALIZADO] Todas las muestras fueron procesadas y el resumen está en:"
echo "  $out_dir/multiqc_report"
