#!/usr/bin/env bash
################################################################################
# Script para comparar rendimiento entre múltiples proyectos QIIME2
# Genera gráficos comparativos de tiempo, memoria, CPU e I/O
# 
# Uso: bash compare_results.sh <proyecto1> <proyecto2> [proyecto3] ...
# Ejemplo: bash compare_results.sh Proyecto1_20251113 Proyecto2_20251114
################################################################################

set -euo pipefail

# ============================================================================
# VERIFICACIÓN DE ARGUMENTOS
# ============================================================================

if [[ $# -lt 2 ]]; then
  echo "ERROR: Debe proporcionar al menos 2 proyectos para comparar"
  echo ""
  echo "Uso: bash $0 <proyecto1> <proyecto2> [proyecto3] ..."
  echo ""
  echo "Ejemplo:"
  echo "  bash $0 Proyecto1_20241113 Proyecto2_20241114"
  echo "  bash $0 Config_Default Config_Optimizado Config_MaxThreads"
  echo ""
  exit 1
fi

# ============================================================================
# CONFIGURACIÓN
# ============================================================================

BASE_DIR="/home/proyecto"
COMPARISON_DIR="$BASE_DIR/project_comparisons"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$COMPARISON_DIR/comparison_$TIMESTAMP"

mkdir -p "$OUTPUT_DIR"

PROJECTS=("$@")
NUM_PROJECTS=${#PROJECTS[@]}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      COMPARACIÓN DE PROYECTOS QIIME2                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Proyectos a comparar: $NUM_PROJECTS"
for i in "${!PROJECTS[@]}"; do
  echo "  $((i+1)). ${PROJECTS[$i]}"
done
echo ""
echo "Directorio de salida: $OUTPUT_DIR"
echo ""

# ============================================================================
# VERIFICAR QUE EXISTEN LOS PROYECTOS Y SUS MÉTRICAS
# ============================================================================

echo "Verificando proyectos..."
for PROJECT in "${PROJECTS[@]}"; do
  PROJECT_DIR="$BASE_DIR/$PROJECT"
  
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: No existe el directorio: $PROJECT_DIR"
    exit 1
  fi
  
  TIMING_FILE="$PROJECT_DIR/logs/timing_summary.csv"
  if [[ ! -f "$TIMING_FILE" ]]; then
    echo "ERROR: No se encontró timing_summary.csv en $PROJECT"
    echo "Debe ejecutar el pipeline monitoreado primero:"
    echo "  bash pipeline1_stats.sh $PROJECT"
    exit 1
  fi
  
  echo "  ✓ $PROJECT - OK"
done
echo ""

# ============================================================================
# CONSOLIDAR DATOS DE TODOS LOS PROYECTOS
# ============================================================================

echo "Consolidando datos..."

# Crear CSV consolidado con todos los datos
CONSOLIDATED_CSV="$OUTPUT_DIR/consolidated_metrics.csv"
echo "project,step,duration_seconds,duration_minutes,max_memory_kb,max_memory_mb,max_memory_gb,cpu_percent,io_read_mb,io_write_mb,io_total_mb,exit_status" > "$CONSOLIDATED_CSV"

for PROJECT in "${PROJECTS[@]}"; do
  TIMING_FILE="$BASE_DIR/$PROJECT/logs/timing_summary.csv"
  
  # Agregar datos saltando el encabezado
  tail -n +2 "$TIMING_FILE" | while IFS=',' read -r step start_time end_time duration_sec duration_min max_mem_kb max_mem_mb max_mem_gb cpu_pct io_read io_write io_total exit_code; do
    echo "$PROJECT,$step,$duration_sec,$duration_min,$max_mem_kb,$max_mem_mb,$max_mem_gb,$cpu_pct,$io_read,$io_write,$io_total,$exit_code" >> "$CONSOLIDATED_CSV"
  done
done

echo "  ✓ Datos consolidados en: $CONSOLIDATED_CSV"
echo ""

# ============================================================================
# COPIAR ARCHIVOS DE MÉTRICAS INDIVIDUALES
# ============================================================================

echo "Copiando métricas individuales..."
for PROJECT in "${PROJECTS[@]}"; do
  PROJECT_METRICS_DIR="$OUTPUT_DIR/individual_metrics/$PROJECT"
  mkdir -p "$PROJECT_METRICS_DIR"
  
  # Copiar timing summary
  cp "$BASE_DIR/$PROJECT/logs/timing_summary.csv" "$PROJECT_METRICS_DIR/"
  
  # Copiar resumen del pipeline si existe
  if [[ -f "$BASE_DIR/$PROJECT/metrics/pipeline_summary.txt" ]]; then
    cp "$BASE_DIR/$PROJECT/metrics/pipeline_summary.txt" "$PROJECT_METRICS_DIR/"
  fi
  
  # Copiar archivos pidstat (primeros 5 para no saturar)
  PIDSTAT_FILES=("$BASE_DIR/$PROJECT/metrics"/*_pidstat.csv)
  if [[ ${#PIDSTAT_FILES[@]} -gt 0 ]] && [[ -f "${PIDSTAT_FILES[0]}" ]]; then
    mkdir -p "$PROJECT_METRICS_DIR/pidstat_samples"
    for i in {0..4}; do
      if [[ -f "${PIDSTAT_FILES[$i]}" ]]; then
        cp "${PIDSTAT_FILES[$i]}" "$PROJECT_METRICS_DIR/pidstat_samples/"
      fi
    done
  fi
done
echo "  ✓ Métricas individuales copiadas"
echo ""

# ============================================================================
# GENERAR GRÁFICOS COMPARATIVOS CON PYTHON
# ============================================================================

echo "Generando gráficos comparativos..."

cat > "$OUTPUT_DIR/generate_comparison_plots.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Generador de gráficos comparativos entre múltiples proyectos QIIME2
"""

import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import sys
import os

def load_consolidated_data(csv_file):
    """Cargar datos consolidados de todos los proyectos"""
    df = pd.read_csv(csv_file)
    return df

def get_project_summary(df):
    """Calcular métricas agregadas por proyecto"""
    summary = df.groupby('project').agg({
        'duration_minutes': 'sum',
        'max_memory_gb': 'sum',
        'cpu_percent': 'mean',
        'io_total_mb': 'sum'
    }).reset_index()
    
    summary.columns = ['project', 'total_time_min', 'total_memory_gb', 'avg_cpu_percent', 'total_io_mb']
    summary['total_io_gb'] = summary['total_io_mb'] / 1024
    
    return summary

def plot_total_time_comparison(summary, output_dir):
    """Gráfico de tiempo total por proyecto"""
    fig = go.Figure()
    
    colors = ['#FF6B6B', '#4ECDC4', '#45B7D1', '#FFA07A', '#98D8C8']
    
    fig.add_trace(go.Bar(
        x=summary['project'],
        y=summary['total_time_min'],
        text=[f"{v:.2f} min" for v in summary['total_time_min']],
        textposition='outside',
        marker=dict(
            color=colors[:len(summary)],
            line=dict(color='black', width=2)
        ),
        hovertemplate='<b>%{x}</b><br>Tiempo total: %{y:.2f} min<extra></extra>'
    ))
    
    # Línea de promedio
    avg_time = summary['total_time_min'].mean()
    fig.add_hline(y=avg_time, line_dash="dash", line_color="red",
                  annotation_text=f"Promedio: {avg_time:.2f} min")
    
    fig.update_layout(
        title='Comparación de Tiempo Total de Ejecución<br><sub>Menor es mejor</sub>',
        xaxis_title='Proyecto',
        yaxis_title='Tiempo Total (minutos)',
        template='plotly_white',
        height=600,
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/01_time_comparison.html")
    print("✓ Gráfico 1: Comparación de tiempo total")

def plot_memory_comparison(summary, output_dir):
    """Gráfico de uso de memoria por proyecto"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=summary['project'],
        y=summary['total_memory_gb'],
        text=[f"{v:.2f} GB" for v in summary['total_memory_gb']],
        textposition='outside',
        marker=dict(
            color=summary['total_memory_gb'],
            colorscale='YlOrRd',
            showscale=True,
            colorbar=dict(title="GB")
        ),
        hovertemplate='<b>%{x}</b><br>Memoria total: %{y:.2f} GB<extra></extra>'
    ))
    
    avg_mem = summary['total_memory_gb'].mean()
    fig.add_hline(y=avg_mem, line_dash="dash", line_color="blue",
                  annotation_text=f"Promedio: {avg_mem:.2f} GB")
    
    fig.update_layout(
        title='Comparación de Uso Acumulado de Memoria<br><sub>Suma de memoria máxima en cada paso</sub>',
        xaxis_title='Proyecto',
        yaxis_title='Memoria Total (GB)',
        template='plotly_white',
        height=600,
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/02_memory_comparison.html")
    print("✓ Gráfico 2: Comparación de memoria")

def plot_cpu_comparison(summary, output_dir):
    """Gráfico de uso de CPU por proyecto"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=summary['project'],
        y=summary['avg_cpu_percent'],
        text=[f"{v:.1f}%" for v in summary['avg_cpu_percent']],
        textposition='outside',
        marker=dict(
            color=summary['avg_cpu_percent'],
            colorscale='Blues',
            showscale=True,
            colorbar=dict(title="%")
        ),
        hovertemplate='<b>%{x}</b><br>CPU promedio: %{y:.1f}%<extra></extra>'
    ))
    
    avg_cpu = summary['avg_cpu_percent'].mean()
    fig.add_hline(y=avg_cpu, line_dash="dash", line_color="green",
                  annotation_text=f"Promedio: {avg_cpu:.1f}%")
    
    fig.update_layout(
        title='Comparación de Uso Promedio de CPU<br><sub>Mayor utilización indica mejor aprovechamiento</sub>',
        xaxis_title='Proyecto',
        yaxis_title='CPU Promedio (%)',
        template='plotly_white',
        height=600,
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/03_cpu_comparison.html")
    print("✓ Gráfico 3: Comparación de CPU")

def plot_io_comparison(summary, output_dir):
    """Gráfico de I/O por proyecto"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=summary['project'],
        y=summary['total_io_gb'],
        text=[f"{v:.2f} GB" for v in summary['total_io_gb']],
        textposition='outside',
        marker=dict(
            color=summary['total_io_gb'],
            colorscale='Greens',
            showscale=True,
            colorbar=dict(title="GB")
        ),
        hovertemplate='<b>%{x}</b><br>I/O total: %{y:.2f} GB<extra></extra>'
    ))
    
    avg_io = summary['total_io_gb'].mean()
    fig.add_hline(y=avg_io, line_dash="dash", line_color="purple",
                  annotation_text=f"Promedio: {avg_io:.2f} GB")
    
    fig.update_layout(
        title='Comparación de I/O Total (Lectura + Escritura)<br><sub>Operaciones de disco</sub>',
        xaxis_title='Proyecto',
        yaxis_title='I/O Total (GB)',
        template='plotly_white',
        height=600,
        showlegend=False
    )
    
    fig.write_html(f"{output_dir}/04_io_comparison.html")
    print("✓ Gráfico 4: Comparación de I/O")

def plot_overall_dashboard(summary, output_dir):
    """Dashboard comparativo general"""
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=('Tiempo Total', 'Memoria Total', 'CPU Promedio', 'I/O Total'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'bar'}]]
    )
    
    colors = ['#FF6B6B', '#4ECDC4', '#45B7D1', '#FFA07A', '#98D8C8']
    
    # Tiempo
    fig.add_trace(
        go.Bar(x=summary['project'], y=summary['total_time_min'],
               marker=dict(color=colors[:len(summary)]),
               text=[f"{v:.1f}" for v in summary['total_time_min']],
               textposition='outside',
               showlegend=False),
        row=1, col=1
    )
    
    # Memoria
    fig.add_trace(
        go.Bar(x=summary['project'], y=summary['total_memory_gb'],
               marker=dict(color=colors[:len(summary)]),
               text=[f"{v:.1f}" for v in summary['total_memory_gb']],
               textposition='outside',
               showlegend=False),
        row=1, col=2
    )
    
    # CPU
    fig.add_trace(
        go.Bar(x=summary['project'], y=summary['avg_cpu_percent'],
               marker=dict(color=colors[:len(summary)]),
               text=[f"{v:.1f}" for v in summary['avg_cpu_percent']],
               textposition='outside',
               showlegend=False),
        row=2, col=1
    )
    
    # I/O
    fig.add_trace(
        go.Bar(x=summary['project'], y=summary['total_io_gb'],
               marker=dict(color=colors[:len(summary)]),
               text=[f"{v:.1f}" for v in summary['total_io_gb']],
               textposition='outside',
               showlegend=False),
        row=2, col=2
    )
    
    fig.update_yaxes(title_text="Minutos", row=1, col=1)
    fig.update_yaxes(title_text="GB", row=1, col=2)
    fig.update_yaxes(title_text="%", row=2, col=1)
    fig.update_yaxes(title_text="GB", row=2, col=2)
    
    fig.update_layout(
        title_text="Dashboard Comparativo de Recursos",
        height=900,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/05_overall_dashboard.html")
    print("✓ Gráfico 5: Dashboard general")

def plot_step_by_step_comparison(df, output_dir):
    """Comparación paso a paso entre proyectos"""
    
    # Obtener pasos comunes a todos los proyectos
    steps_per_project = df.groupby('project')['step'].apply(set)
    common_steps = set.intersection(*steps_per_project.values)
    
    if not common_steps:
        print("⚠️  No hay pasos comunes entre todos los proyectos")
        return
    
    # Filtrar solo pasos comunes
    df_common = df[df['step'].isin(common_steps)]
    
    # Crear gráfico por métrica
    metrics = [
        ('duration_minutes', 'Tiempo (minutos)', 'Duración'),
        ('max_memory_gb', 'Memoria (GB)', 'Memoria'),
        ('cpu_percent', 'CPU (%)', 'CPU'),
        ('io_total_mb', 'I/O (MB)', 'I/O')
    ]
    
    for metric, ylabel, title in metrics:
        fig = go.Figure()
        
        for project in df_common['project'].unique():
            project_data = df_common[df_common['project'] == project].sort_values('step')
            
            fig.add_trace(go.Scatter(
                x=project_data['step'],
                y=project_data[metric],
                mode='lines+markers',
                name=project,
                line=dict(width=3),
                marker=dict(size=8),
                hovertemplate='<b>%{fullData.name}</b><br>Paso: %{x}<br>Valor: %{y:.2f}<extra></extra>'
            ))
        
        fig.update_layout(
            title=f'Comparación Paso a Paso: {title}',
            xaxis_title='Paso del Pipeline',
            yaxis_title=ylabel,
            template='plotly_white',
            height=600,
            xaxis={'tickangle': -45},
            hovermode='x unified',
            legend=dict(
                orientation="h",
                yanchor="bottom",
                y=1.02,
                xanchor="right",
                x=1
            )
        )
        
        filename = f"06_step_comparison_{metric.split('_')[0]}.html"
        fig.write_html(f"{output_dir}/{filename}")
    
    print("✓ Gráficos 6-9: Comparaciones paso a paso")

def plot_efficiency_analysis(summary, output_dir):
    """Análisis de eficiencia (tiempo vs recursos)"""
    fig = go.Figure()
    
    # Normalizar valores para comparación
    summary['norm_time'] = summary['total_time_min'] / summary['total_time_min'].max()
    summary['norm_memory'] = summary['total_memory_gb'] / summary['total_memory_gb'].max()
    summary['norm_io'] = summary['total_io_gb'] / summary['total_io_gb'].max()
    
    # Calcular score de eficiencia (menor es mejor)
    summary['efficiency_score'] = (summary['norm_time'] + summary['norm_memory'] + summary['norm_io']) / 3
    
    fig.add_trace(go.Scatter(
        x=summary['total_time_min'],
        y=summary['total_memory_gb'],
        mode='markers+text',
        text=summary['project'],
        textposition='top center',
        marker=dict(
            size=summary['total_io_gb'] * 5,
            color=summary['efficiency_score'],
            colorscale='RdYlGn_r',
            showscale=True,
            colorbar=dict(title="Score<br>Eficiencia"),
            line=dict(color='black', width=2)
        ),
        hovertemplate='<b>%{text}</b><br>Tiempo: %{x:.2f} min<br>Memoria: %{y:.2f} GB<br>I/O: %{marker.size:.2f} GB<extra></extra>'
    ))
    
    fig.update_layout(
        title='Análisis de Eficiencia: Tiempo vs Memoria<br><sub>Tamaño del marcador = I/O, Color = Score de eficiencia</sub>',
        xaxis_title='Tiempo Total (minutos)',
        yaxis_title='Memoria Total (GB)',
        template='plotly_white',
        height=700
    )
    
    fig.write_html(f"{output_dir}/10_efficiency_analysis.html")
    print("✓ Gráfico 10: Análisis de eficiencia")

def create_comparison_report(summary, df, output_dir):
    """Crear reporte HTML con todas las comparaciones"""
    
    html_files = sorted([f for f in os.listdir(output_dir) if f.endswith('.html') and f != 'index.html'])
    
    # Identificar el mejor proyecto en cada métrica
    best_time = summary.loc[summary['total_time_min'].idxmin(), 'project']
    best_memory = summary.loc[summary['total_memory_gb'].idxmin(), 'project']
    best_cpu = summary.loc[summary['avg_cpu_percent'].idxmax(), 'project']
    best_io = summary.loc[summary['total_io_gb'].idxmin(), 'project']
    
    html_content = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Comparación de Proyectos QIIME2</title>
<style>
body{{font-family:Arial,sans-serif;margin:20px;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);}}
.container{{max-width:1600px;margin:0 auto;background:white;border-radius:15px;padding:30px;box-shadow:0 10px 40px rgba(0,0,0,0.3);}}
h1{{color:#2c3e50;border-bottom:4px solid #3498db;padding-bottom:15px;}}
h2{{color:#34495e;margin-top:40px;border-left:5px solid #3498db;padding-left:15px;}}
.stats-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px;margin:30px 0;}}
.stat-card{{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:20px;border-radius:10px;text-align:center;box-shadow:0 4px 6px rgba(0,0,0,0.1);}}
.stat-value{{font-size:2em;font-weight:bold;margin:10px 0;}}
.winner-badge{{background:#28a745;color:white;padding:5px 15px;border-radius:20px;font-size:0.9em;display:inline-block;margin:5px;}}
.graph-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(600px,1fr));gap:25px;margin:30px 0;}}
.graph-card{{background:white;border-radius:12px;padding:20px;box-shadow:0 4px 6px rgba(0,0,0,0.1);border:1px solid #e0e0e0;}}
.graph-card:hover{{transform:translateY(-5px);box-shadow:0 12px 24px rgba(0,0,0,0.15);}}
.graph-card h3{{color:#2980b9;margin-top:0;}}
iframe{{width:100%;height:600px;border:2px solid #ddd;border-radius:8px;margin:10px 0;}}
table{{width:100%;border-collapse:collapse;margin:20px 0;}}
th,td{{padding:12px;text-align:left;border-bottom:1px solid #ddd;}}
th{{background:#3498db;color:white;}}
tr:hover{{background:#f5f5f5;}}
.winner{{background:#d4edda;font-weight:bold;}}
</style></head><body><div class="container">
<h1>📊 Comparación de Proyectos QIIME2</h1>
<p style="font-size:1.1em;color:#555;"><strong>Fecha:</strong> {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
<p style="font-size:1.1em;color:#555;"><strong>Proyectos comparados:</strong> {len(summary)}</p>

<h2>🏆 Mejores Rendimientos por Categoría</h2>
<div style="background:#f8f9fa;padding:20px;border-radius:10px;margin:20px 0;">
<p>⚡ <strong>Más Rápido:</strong> <span class="winner-badge">{best_time}</span> - {summary[summary['project']==best_time]['total_time_min'].values[0]:.2f} minutos</p>
<p>💾 <strong>Menor Memoria:</strong> <span class="winner-badge">{best_memory}</span> - {summary[summary['project']==best_memory]['total_memory_gb'].values[0]:.2f} GB</p>
<p>🔥 <strong>Mayor Uso de CPU:</strong> <span class="winner-badge">{best_cpu}</span> - {summary[summary['project']==best_cpu]['avg_cpu_percent'].values[0]:.1f}%</p>
<p>💿 <strong>Menor I/O:</strong> <span class="winner-badge">{best_io}</span> - {summary[summary['project']==best_io]['total_io_gb'].values[0]:.2f} GB</p>
</div>

<h2>📈 Resumen Comparativo</h2>
<table>
<tr><th>Proyecto</th><th>Tiempo (min)</th><th>Memoria (GB)</th><th>CPU (%)</th><th>I/O (GB)</th></tr>
"""
    
    for _, row in summary.iterrows():
        time_class = ' class="winner"' if row['project'] == best_time else ''
        mem_class = ' class="winner"' if row['project'] == best_memory else ''
        cpu_class = ' class="winner"' if row['project'] == best_cpu else ''
        io_class = ' class="winner"' if row['project'] == best_io else ''
        
        html_content += f"""<tr>
<td><strong>{row['project']}</strong></td>
<td{time_class}>{row['total_time_min']:.2f}</td>
<td{mem_class}>{row['total_memory_gb']:.2f}</td>
<td{cpu_class}>{row['avg_cpu_percent']:.1f}</td>
<td{io_class}>{row['total_io_gb']:.2f}</td>
</tr>"""
    
    html_content += """</table>

<h2>📊 Gráficos Comparativos</h2>
<div class="graph-grid">"""
    
    for plot_file in html_files:
        plot_name = plot_file.replace('.html', '').replace('_', ' ').title()
        html_content += f"""<div class="graph-card">
<h3>{plot_name}</h3>
<iframe src="{plot_file}"></iframe>
</div>"""
    
    html_content += """</div>

<h2>💡 Recomendaciones</h2>
<div style="background:#d4edda;border-left:5px solid #28a745;padding:20px;border-radius:8px;">
<h4 style="margin-top:0;color:#155724;">Análisis y Sugerencias</h4>
<ul style="color:#155724;line-height:1.8;">
"""
    
    # Análisis automático
    time_diff = ((summary['total_time_min'].max() - summary['total_time_min'].min()) / summary['total_time_min'].min() * 100)
    html_content += f"<li><strong>Variación en tiempo:</strong> {time_diff:.1f}% de diferencia entre el más rápido y el más lento. "
    if time_diff > 20:
        html_content += "Considere adoptar la configuración del proyecto más rápido."
    else:
        html_content += "Las configuraciones tienen rendimiento similar."
    html_content += "</li>"
    
    mem_diff = ((summary['total_memory_gb'].max() - summary['total_memory_gb'].min()) / summary['total_memory_gb'].min() * 100)
    html_content += f"<li><strong>Variación en memoria:</strong> {mem_diff:.1f}% de diferencia. "
    if mem_diff > 30:
        html_content += f"El proyecto {best_memory} es significativamente más eficiente en uso de memoria."
    html_content += "</li>"
    
    html_content += f"""<li><strong>Uso de CPU:</strong> El proyecto {best_cpu} tiene el mejor aprovechamiento de CPU ({summary[summary['project']==best_cpu]['avg_cpu_percent'].values[0]:.1f}%). Esto indica mejor paralelización.</li>
<li><strong>I/O de disco:</strong> El proyecto {best_io} minimiza las operaciones de disco, lo cual mejora el rendimiento en sistemas con I/O limitado.</li>
</ul>
</div>

<div style="text-align:center;margin-top:50px;padding-top:20px;border-top:2px solid #ddd;color:#7f8c8d;">
<p>Generado por QIIME2 Pipeline Comparison Tool</p>
</div>
</div></body></html>"""
    
    with open(f"{output_dir}/index.html", 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    print("✓ Reporte comparativo HTML generado")

def main():
    if len(sys.argv) != 2:
        print("Usage: python generate_comparison_plots.py <consolidated_csv>")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    output_dir = os.path.dirname(csv_file)
    
    print("\nGenerando gráficos comparativos...")
    print("="*60)
    
    # Cargar datos
    df = load_consolidated_data(csv_file)
    summary = get_project_summary(df)
    
    # Generar gráficos
    plot_total_time_comparison(summary, output_dir)
    plot_memory_comparison(summary, output_dir)
    plot_cpu_comparison(summary, output_dir)
    plot_io_comparison(summary, output_dir)
    plot_overall_dashboard(summary, output_dir)
    plot_step_by_step_comparison(df, output_dir)
    plot_efficiency_analysis(summary, output_dir)
    
    # Generar reporte final
    create_comparison_report(summary, df, output_dir)
    
    print("="*60)
    print(f"\n✓ Comparación completada")
    print(f"Reporte: {output_dir}/index.html\n")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

# ============================================================================
# EJECUTAR GENERACIÓN DE GRÁFICOS
# ============================================================================

/opt/conda/bin/conda run -n qiime2 python "$OUTPUT_DIR/generate_comparison_plots.py" "$CONSOLIDATED_CSV"

if [[ $? -ne 0 ]]; then
  echo "ERROR: Falló la generación de gráficos"
  exit 1
fi

# ============================================================================
# GENERAR RESUMEN EN TEXTO
# ============================================================================

echo "Generando resumen en texto..."

SUMMARY_FILE="$OUTPUT_DIR/comparison_summary.txt"

cat > "$SUMMARY_FILE" << EOF
╔══════════════════════════════════════════════════════════╗
║         RESUMEN DE COMPARACIÓN DE PROYECTOS              ║
╚══════════════════════════════════════════════════════════╝

Fecha de comparación: $(date '+%Y-%m-%d %H:%M:%S')
Número de proyectos: $NUM_PROJECTS

PROYECTOS COMPARADOS
====================
EOF

for i in "${!PROJECTS[@]}"; do
  echo "$((i+1)). ${PROJECTS[$i]}" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" << EOF

MÉTRICAS POR PROYECTO
=====================
EOF

# Agregar métricas de cada proyecto
for PROJECT in "${PROJECTS[@]}"; do
  TIMING_FILE="$BASE_DIR/$PROJECT/logs/timing_summary.csv"
  
  # Calcular totales
  TOTAL_TIME=$(awk -F',' 'NR>1 {sum+=$5} END {printf "%.2f", sum}' "$TIMING_FILE")
  TOTAL_MEM=$(awk -F',' 'NR>1 {sum+=$8} END {printf "%.2f", sum}' "$TIMING_FILE")
  AVG_CPU=$(awk -F',' 'NR>1 {sum+=$9; count++} END {printf "%.2f", sum/count}' "$TIMING_FILE")
  TOTAL_IO=$(awk -F',' 'NR>1 {sum+=$12} END {printf "%.2f", sum/1024}' "$TIMING_FILE")
  
  cat >> "$SUMMARY_FILE" << EOF

$PROJECT
────────────────────────────────────────────
  Tiempo total:      $TOTAL_TIME minutos
  Memoria total:     $TOTAL_MEM GB
  CPU promedio:      $AVG_CPU %
  I/O total:         $TOTAL_IO GB
EOF
done

cat >> "$SUMMARY_FILE" << EOF


ARCHIVOS GENERADOS
==================
- Datos consolidados:  $CONSOLIDATED_CSV
- Gráficos:            $OUTPUT_DIR/*.html
- Reporte principal:   $OUTPUT_DIR/index.html
- Métricas por proyecto: $OUTPUT_DIR/individual_metrics/

═══════════════════════════════════════════════════════════
Para ver los gráficos comparativos:
  firefox $OUTPUT_DIR/index.html

Para comparar configuraciones específicas de pasos:
  Revise los gráficos 06-09 para análisis paso a paso
═══════════════════════════════════════════════════════════
EOF

# ============================================================================
# MOSTRAR RESUMEN FINAL
# ============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         COMPARACIÓN COMPLETADA EXITOSAMENTE          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
cat "$SUMMARY_FILE"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "SIGUIENTE PASO: Ver reporte HTML"
echo "  firefox $OUTPUT_DIR/index.html"
echo ""
echo "O revisar resumen en texto:"
echo "  cat $SUMMARY_FILE"
echo "═══════════════════════════════════════════════════════"
echo ""