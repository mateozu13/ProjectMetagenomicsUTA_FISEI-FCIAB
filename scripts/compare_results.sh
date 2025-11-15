#!/usr/bin/env bash
################################################################################
# Script para COMPARAR múltiples ejecuciones del pipeline
# Útil para evaluar el impacto de optimizaciones
#
# Uso: bash compare_pipeline_runs.sh <proyecto1> <proyecto2> [proyecto3] ...
# Ejemplo: bash compare_pipeline_runs.sh Run1_Original Run2_Optimizado
################################################################################

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "ERROR: Debe proporcionar al menos 2 proyectos para comparar"
  echo ""
  echo "Uso: bash $0 <proyecto1> <proyecto2> [proyecto3] ..."
  echo ""
  echo "Ejemplo:"
  echo "  bash $0 Proyecto_Original Proyecto_Optimizado"
  echo ""
  exit 1
fi

BASE_DIR="/home/proyecto"
COMPARISON_DIR="$BASE_DIR/pipeline_comparison_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$COMPARISON_DIR"

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║       COMPARACIÓN DE EJECUCIONES DEL PIPELINE         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Proyectos a comparar: $@"
echo "Directorio de salida: $COMPARISON_DIR"
echo ""

# Verificar que existen los proyectos y sus métricas
for PROJECT in "$@"; do
  if [[ ! -d "$BASE_DIR/$PROJECT" ]]; then
    echo " ERROR: No existe el proyecto $PROJECT"
    exit 1
  fi
  
  if [[ ! -f "$BASE_DIR/$PROJECT/logs/timing_summary.csv" ]]; then
    echo " ERROR: No se encontraron métricas para $PROJECT"
    echo "   Asegúrese de ejecutar process_qiime2_stats_mejorado.sh primero"
    exit 1
  fi
  
  echo " $PROJECT - métricas encontradas"
done

echo ""

# ============================================================================
# SCRIPT PYTHON PARA COMPARACIÓN
# ============================================================================

cat > "$COMPARISON_DIR/compare_runs.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Comparador de múltiples ejecuciones del pipeline QIIME2
Genera gráficos comparativos y tablas de mejoras
"""

import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import sys
import os

def load_all_runs(base_dir, projects):
    """Cargar datos de todos los proyectos"""
    all_data = {}
    
    for project in projects:
        timing_file = f"{base_dir}/{project}/logs/timing_summary.csv"
        summary_file = f"{base_dir}/{project}/metrics/pipeline_summary.txt"
        
        # Cargar CSV
        df = pd.read_csv(timing_file)
        
        # Extraer tiempo total del resumen
        total_time = 0
        if os.path.exists(summary_file):
            with open(summary_file, 'r') as f:
                for line in f:
                    if 'Duración (segundos):' in line:
                        total_time = float(line.split(':')[1].strip().split()[0])
                        break
        
        all_data[project] = {
            'df': df,
            'total_time_seconds': total_time,
            'total_time_minutes': total_time / 60,
            'total_memory_gb': df['max_memory_gb'].sum(),
            'avg_cpu': df['cpu_percent'].mean(),
            'total_io_gb': df['io_total_mb'].sum() / 1024
        }
    
    return all_data

def plot_total_time_comparison(all_data, output_dir):
    """Comparación de tiempo total"""
    projects = list(all_data.keys())
    times_min = [all_data[p]['total_time_minutes'] for p in projects]
    times_sec = [all_data[p]['total_time_seconds'] for p in projects]
    
    # Calcular mejora respecto al primero
    base_time = times_min[0]
    improvements = [(base_time - t) / base_time * 100 for t in times_min]
    
    fig = go.Figure()
    
    # Barras de tiempo
    fig.add_trace(go.Bar(
        x=projects,
        y=times_min,
        text=[f"{t:.1f} min<br>({s:.0f}s)" for t, s in zip(times_min, times_sec)],
        textposition='outside',
        marker=dict(
            color=times_min,
            colorscale='RdYlGn_r',
            showscale=False
        ),
        hovertemplate='<b>%{x}</b><br>Tiempo: %{y:.2f} min<br>Mejora: %{customdata:.1f}%<extra></extra>',
        customdata=improvements
    ))
    
    # Línea de referencia (primer proyecto)
    fig.add_hline(y=base_time, line_dash="dash", line_color="red",
                  annotation_text=f"Baseline: {base_time:.1f} min")
    
    # Agregar porcentajes de mejora
    for i, (proj, improvement) in enumerate(zip(projects, improvements)):
        if i > 0:  # Skip baseline
            color = "green" if improvement > 0 else "red"
            symbol = "↓" if improvement > 0 else "↑"
            fig.add_annotation(
                x=proj, y=times_min[i],
                text=f"{symbol} {abs(improvement):.1f}%",
                showarrow=False,
                yshift=20,
                font=dict(color=color, size=14, family="Arial Black")
            )
    
    fig.update_layout(
        title='Comparación de Tiempo Total de Ejecución<br><sub>Tiempo requerido para completar todo el pipeline</sub>',
        xaxis_title='Proyecto',
        yaxis_title='Tiempo (minutos)',
        template='plotly_white',
        height=600
    )
    
    fig.write_html(f"{output_dir}/comparison_01_total_time.html")
    print("✓ Gráfico 1: Tiempo total")

def plot_step_by_step_comparison(all_data, output_dir):
    """Comparación paso a paso"""
    projects = list(all_data.keys())
    
    # Obtener todos los pasos únicos
    all_steps = set()
    for data in all_data.values():
        all_steps.update(data['df']['step'].unique())
    all_steps = sorted(list(all_steps))
    
    fig = go.Figure()
    
    for project in projects:
        df = all_data[project]['df']
        
        # Crear un diccionario de step -> time
        step_times = dict(zip(df['step'], df['duration_minutes']))
        
        # Crear lista con tiempos (0 si no existe el paso)
        times = [step_times.get(step, 0) for step in all_steps]
        
        fig.add_trace(go.Bar(
            name=project,
            x=all_steps,
            y=times,
            text=[f"{t:.1f}" if t > 0 else "" for t in times],
            textposition='outside'
        ))
    
    fig.update_layout(
        title='Comparación Paso a Paso<br><sub>Duración de cada paso en diferentes ejecuciones</sub>',
        xaxis_title='Paso del Pipeline',
        yaxis_title='Duración (minutos)',
        barmode='group',
        template='plotly_white',
        height=700,
        xaxis={'tickangle': -45},
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1)
    )
    
    fig.write_html(f"{output_dir}/comparison_02_step_by_step.html")
    print("✓ Gráfico 2: Comparación por pasos")

def plot_resource_comparison(all_data, output_dir):
    """Comparación de recursos (Memoria, CPU, I/O)"""
    projects = list(all_data.keys())
    
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=('Tiempo Total', 'Memoria Total', 'CPU Promedio', 'I/O Total'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'bar'}]]
    )
    
    # Tiempo
    times = [all_data[p]['total_time_minutes'] for p in projects]
    fig.add_trace(
        go.Bar(x=projects, y=times, name='Tiempo',
               marker_color='indianred',
               text=[f"{t:.1f} min" for t in times],
               textposition='outside'),
        row=1, col=1
    )
    
    # Memoria
    memory = [all_data[p]['total_memory_gb'] for p in projects]
    fig.add_trace(
        go.Bar(x=projects, y=memory, name='Memoria',
               marker_color='lightsalmon',
               text=[f"{m:.2f} GB" for m in memory],
               textposition='outside'),
        row=1, col=2
    )
    
    # CPU
    cpu = [all_data[p]['avg_cpu'] for p in projects]
    fig.add_trace(
        go.Bar(x=projects, y=cpu, name='CPU',
               marker_color='lightblue',
               text=[f"{c:.1f}%" for c in cpu],
               textposition='outside'),
        row=2, col=1
    )
    
    # I/O
    io = [all_data[p]['total_io_gb'] for p in projects]
    fig.add_trace(
        go.Bar(x=projects, y=io, name='I/O',
               marker_color='lightgreen',
               text=[f"{i:.2f} GB" for i in io],
               textposition='outside'),
        row=2, col=2
    )
    
    fig.update_yaxes(title_text="Minutos", row=1, col=1)
    fig.update_yaxes(title_text="GB", row=1, col=2)
    fig.update_yaxes(title_text="%", row=2, col=1)
    fig.update_yaxes(title_text="GB", row=2, col=2)
    
    fig.update_layout(
        title_text="Comparación de Recursos Globales",
        height=800,
        showlegend=False,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/comparison_03_resources.html")
    print("✓ Gráfico 3: Recursos globales")

def plot_improvement_summary(all_data, output_dir):
    """Resumen de mejoras respecto al baseline"""
    projects = list(all_data.keys())
    base_project = projects[0]
    
    if len(projects) < 2:
        print("  Se necesitan al menos 2 proyectos para calcular mejoras")
        return
    
    improvements = []
    
    for project in projects[1:]:
        time_improv = (all_data[base_project]['total_time_minutes'] - 
                       all_data[project]['total_time_minutes']) / \
                      all_data[base_project]['total_time_minutes'] * 100
        
        mem_improv = (all_data[base_project]['total_memory_gb'] - 
                      all_data[project]['total_memory_gb']) / \
                     all_data[base_project]['total_memory_gb'] * 100
        
        io_improv = (all_data[base_project]['total_io_gb'] - 
                     all_data[project]['total_io_gb']) / \
                    all_data[base_project]['total_io_gb'] * 100
        
        improvements.append({
            'project': project,
            'time': time_improv,
            'memory': mem_improv,
            'io': io_improv
        })
    
    df_improv = pd.DataFrame(improvements)
    
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        name='Tiempo',
        x=df_improv['project'],
        y=df_improv['time'],
        text=[f"{v:+.1f}%" for v in df_improv['time']],
        textposition='outside',
        marker_color=['green' if v > 0 else 'red' for v in df_improv['time']]
    ))
    
    fig.add_trace(go.Bar(
        name='Memoria',
        x=df_improv['project'],
        y=df_improv['memory'],
        text=[f"{v:+.1f}%" for v in df_improv['memory']],
        textposition='outside',
        marker_color=['green' if v > 0 else 'red' for v in df_improv['memory']]
    ))
    
    fig.add_trace(go.Bar(
        name='I/O',
        x=df_improv['project'],
        y=df_improv['io'],
        text=[f"{v:+.1f}%" for v in df_improv['io']],
        textposition='outside',
        marker_color=['green' if v > 0 else 'red' for v in df_improv['io']]
    ))
    
    fig.add_hline(y=0, line_dash="dash", line_color="gray")
    
    fig.update_layout(
        title=f'Mejoras Respecto al Baseline ({base_project})<br><sub>Valores positivos = mejora, negativos = empeoramiento</sub>',
        xaxis_title='Proyecto',
        yaxis_title='Mejora (%)',
        barmode='group',
        template='plotly_white',
        height=600,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1)
    )
    
    fig.write_html(f"{output_dir}/comparison_04_improvements.html")
    print("✓ Gráfico 4: Resumen de mejoras")

def create_comparison_table(all_data, output_dir):
    """Tabla comparativa detallada"""
    projects = list(all_data.keys())
    
    data = []
    for project in projects:
        data.append([
            project,
            f"{all_data[project]['total_time_minutes']:.2f}",
            f"{all_data[project]['total_time_seconds']:.0f}",
            f"{all_data[project]['total_memory_gb']:.2f}",
            f"{all_data[project]['avg_cpu']:.1f}",
            f"{all_data[project]['total_io_gb']:.2f}"
        ])
    
    df = pd.DataFrame(data, columns=['Proyecto', 'Tiempo (min)', 'Tiempo (seg)', 
                                     'Memoria (GB)', 'CPU (%)', 'I/O (GB)'])
    
    fig = go.Figure(data=[go.Table(
        header=dict(
            values=['<b>' + col + '</b>' for col in df.columns],
            fill_color='paleturquoise',
            align='left',
            font=dict(size=14, color='black')
        ),
        cells=dict(
            values=[df[col] for col in df.columns],
            fill_color='lavender',
            align='left',
            font=dict(size=12)
        )
    )])
    
    fig.update_layout(
        title='Tabla Comparativa Detallada',
        height=400
    )
    
    fig.write_html(f"{output_dir}/comparison_05_table.html")
    print("✓ Tabla comparativa")

def create_index(all_data, output_dir):
    """Crear índice HTML"""
    projects = list(all_data.keys())
    base_project = projects[0]
    
    # Calcular mejora total
    if len(projects) > 1:
        best_time = min([all_data[p]['total_time_minutes'] for p in projects])
        base_time = all_data[base_project]['total_time_minutes']
        total_improvement = (base_time - best_time) / base_time * 100
        best_project = [p for p in projects if all_data[p]['total_time_minutes'] == best_time][0]
    else:
        total_improvement = 0
        best_project = base_project
    
    html = f"""
<!DOCTYPE html>
<html>
<head>
    <title>Comparación de Pipelines - QIIME2</title>
    <meta charset="UTF-8">
    <style>
        body {{
            font-family: Arial, sans-serif;
            margin: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }}
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            padding: 30px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
        }}
        h1 {{
            color: #2c3e50;
            border-bottom: 4px solid #3498db;
            padding-bottom: 15px;
        }}
        .summary {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin: 20px 0;
        }}
        .summary h2 {{
            margin-top: 0;
            color: white;
        }}
        .projects {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }}
        .project-card {{
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            border-left: 5px solid #3498db;
        }}
        .project-card h3 {{
            margin-top: 0;
            color: #2980b9;
        }}
        iframe {{
            width: 100%;
            height: 600px;
            border: 2px solid #ddd;
            border-radius: 8px;
            margin: 20px 0;
        }}
        .graph-section {{
            margin: 40px 0;
        }}
        .best-badge {{
            background: #28a745;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.9em;
            display: inline-block;
            margin-left: 10px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1> Comparación de Ejecuciones del Pipeline QIIME2</h1>
        
        <div class="summary">
            <h2>Resumen Ejecutivo</h2>
            <p><strong>Proyectos comparados:</strong> {len(projects)}</p>
            <p><strong>Proyecto baseline:</strong> {base_project}</p>
            <p><strong>Mejor rendimiento:</strong> {best_project} <span class="best-badge">🏆 MEJOR</span></p>
            <p><strong>Mejora total:</strong> {total_improvement:.1f}% ({(all_data[base_project]['total_time_minutes'] - all_data[best_project]['total_time_minutes']):.1f} minutos ahorrados)</p>
        </div>
        
        <h2>Proyectos Analizados</h2>
        <div class="projects">
"""
    
    for project in projects:
        data = all_data[project]
        hours = int(data['total_time_minutes'] // 60)
        minutes = int(data['total_time_minutes'] % 60)
        
        html += f"""
            <div class="project-card">
                <h3>{project}</h3>
                <p><strong>Tiempo:</strong> {hours}h {minutes}m</p>
                <p><strong>Memoria:</strong> {data['total_memory_gb']:.2f} GB</p>
                <p><strong>CPU:</strong> {data['avg_cpu']:.1f}%</p>
                <p><strong>I/O:</strong> {data['total_io_gb']:.2f} GB</p>
            </div>
"""
    
    html += """
        </div>
        
        <div class="graph-section">
            <h2>Gráfico 1: Tiempo Total</h2>
            <iframe src="comparison_01_total_time.html"></iframe>
        </div>
        
        <div class="graph-section">
            <h2>Gráfico 2: Comparación Paso a Paso</h2>
            <iframe src="comparison_02_step_by_step.html"></iframe>
        </div>
        
        <div class="graph-section">
            <h2>Gráfico 3: Recursos Globales</h2>
            <iframe src="comparison_03_resources.html"></iframe>
        </div>
        
        <div class="graph-section">
            <h2>Gráfico 4: Mejoras Respecto al Baseline</h2>
            <iframe src="comparison_04_improvements.html"></iframe>
        </div>
        
        <div class="graph-section">
            <h2>Tabla Comparativa</h2>
            <iframe src="comparison_05_table.html" style="height: 400px;"></iframe>
        </div>
    </div>
</body>
</html>
"""
    
    with open(f"{output_dir}/index.html", 'w', encoding='utf-8') as f:
        f.write(html)
    
    print("✓ Índice HTML creado")

def main():
    base_dir = sys.argv[1]
    output_dir = sys.argv[2]
    projects = sys.argv[3:]
    
    print("\n" + "="*60)
    print("Comparando ejecuciones del pipeline...")
    print("="*60 + "\n")
    
    # Cargar todos los datos
    all_data = load_all_runs(base_dir, projects)
    
    # Generar gráficos
    plot_total_time_comparison(all_data, output_dir)
    plot_step_by_step_comparison(all_data, output_dir)
    plot_resource_comparison(all_data, output_dir)
    plot_improvement_summary(all_data, output_dir)
    create_comparison_table(all_data, output_dir)
    create_index(all_data, output_dir)
    
    print("\n" + "="*60)
    print(" Comparación completada")
    print("="*60 + "\n")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

# ============================================================================
# EJECUTAR COMPARACIÓN
# ============================================================================

/opt/conda/bin/conda run -n qiime2 python "$COMPARISON_DIR/compare_runs.py" \
  "$BASE_DIR" \
  "$COMPARISON_DIR" \
  "$@"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║            COMPARACIÓN COMPLETADA                      ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo ""
  echo " Resultados en: $COMPARISON_DIR"
  echo " Abrir en navegador: file://$COMPARISON_DIR/index.html"
  echo ""
fi