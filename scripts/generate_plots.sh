#!/usr/bin/env bash
################################################################################
# Generador de gráficos de rendimiento para pipeline QIIME2
# Crea visualizaciones interactivas en HTML usando Python/Plotly
# 
# Uso: bash generate_plots.sh <nombre_proyecto>
################################################################################

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "ERROR: Debe proporcionar el nombre del proyecto"
  echo "Uso: bash $0 <nombre_proyecto>"
  exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="/home/proyecto/$PROJECT_NAME"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$PROJECT_DIR/logs"
PLOTS_DIR="$PROJECT_DIR/performance_plots"

mkdir -p "$PLOTS_DIR"

echo ""
echo "=========================================="
echo "Generador de Gráficos de Rendimiento"
echo "=========================================="
echo "Proyecto: $PROJECT_NAME"
echo ""

# Verificar que existen los archivos de métricas
if [[ ! -f "$LOGS_DIR/timing_summary.csv" ]]; then
  echo "ERROR: No se encontró $LOGS_DIR/timing_summary.csv"
  echo "Debe ejecutar primero el pipeline monitoreado"
  exit 1
fi

# ============================================================================
# SCRIPT PYTHON PARA GENERAR GRÁFICOS
# ============================================================================

cat > "$PLOTS_DIR/generate_plots.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Generador de gráficos de rendimiento para pipeline QIIME2
Crea visualizaciones interactivas usando Plotly
"""

import pandas as pd
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots
import sys
import os
from pathlib import Path

def load_timing_data(timing_file):
    """Cargar datos de timing"""
    df = pd.read_csv(timing_file)
    df['duration_minutes'] = df['duration_seconds'] / 60
    df['max_memory_mb'] = df['max_memory_kb'] / 1024
    return df

def load_dstat_data(dstat_file):
    """Cargar datos de dstat"""
    try:
        # Leer CSV de dstat (saltar líneas de comentario)
        df = pd.read_csv(dstat_file, skiprows=6)
        return df
    except Exception as e:
        print(f"Warning: Could not load {dstat_file}: {e}")
        return None

def plot_timing_summary(df, output_dir):
    """Gráfico de barras de duración por paso"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['duration_minutes'],
        text=df['duration_minutes'].round(2),
        textposition='outside',
        marker=dict(
            color=df['duration_minutes'],
            colorscale='Viridis',
            showscale=True,
            colorbar=dict(title="Minutos")
        ),
        hovertemplate='<b>%{x}</b><br>Duración: %{y:.2f} min<extra></extra>'
    ))
    
    fig.update_layout(
        title='Duración de cada paso del pipeline',
        xaxis_title='Paso',
        yaxis_title='Duración (minutos)',
        template='plotly_white',
        height=500,
        xaxis={'tickangle': -45}
    )
    
    fig.write_html(f"{output_dir}/01_duration_summary.html")
    print("✓ Gráfico 1: Duración por paso")

def plot_memory_usage(df, output_dir):
    """Gráfico de uso de memoria"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['max_memory_mb'],
        text=df['max_memory_mb'].round(0),
        textposition='outside',
        marker=dict(
            color=df['max_memory_mb'],
            colorscale='YlOrRd',
            showscale=True,
            colorbar=dict(title="MB")
        ),
        hovertemplate='<b>%{x}</b><br>Memoria: %{y:.0f} MB<extra></extra>'
    ))
    
    fig.update_layout(
        title='Uso máximo de memoria por paso',
        xaxis_title='Paso',
        yaxis_title='Memoria máxima (MB)',
        template='plotly_white',
        height=500,
        xaxis={'tickangle': -45}
    )
    
    fig.write_html(f"{output_dir}/02_memory_summary.html")
    print("✓ Gráfico 2: Uso de memoria")

def plot_cpu_usage(df, output_dir):
    """Gráfico de uso de CPU"""
    fig = go.Figure()
    
    fig.add_trace(go.Bar(
        x=df['step'],
        y=df['cpu_percent'],
        text=df['cpu_percent'].round(1),
        textposition='outside',
        marker=dict(
            color=df['cpu_percent'],
            colorscale='Blues',
            showscale=True,
            colorbar=dict(title="%")
        ),
        hovertemplate='<b>%{x}</b><br>CPU: %{y:.1f}%<extra></extra>'
    ))
    
    fig.update_layout(
        title='Uso de CPU por paso',
        xaxis_title='Paso',
        yaxis_title='CPU (%)',
        template='plotly_white',
        height=500,
        xaxis={'tickangle': -45}
    )
    
    fig.write_html(f"{output_dir}/03_cpu_summary.html")
    print("✓ Gráfico 3: Uso de CPU")

def plot_resource_comparison(df, output_dir):
    """Gráfico comparativo de recursos (tiempo vs memoria vs CPU)"""
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=('Duración', 'Memoria', 'CPU', 'Resumen'),
        specs=[[{'type': 'bar'}, {'type': 'bar'}],
               [{'type': 'bar'}, {'type': 'scatter'}]]
    )
    
    # Duración
    fig.add_trace(
        go.Bar(x=df['step'], y=df['duration_minutes'], name='Duración',
               marker_color='indianred'),
        row=1, col=1
    )
    
    # Memoria
    fig.add_trace(
        go.Bar(x=df['step'], y=df['max_memory_mb'], name='Memoria',
               marker_color='lightsalmon'),
        row=1, col=2
    )
    
    # CPU
    fig.add_trace(
        go.Bar(x=df['step'], y=df['cpu_percent'], name='CPU',
               marker_color='lightblue'),
        row=2, col=1
    )
    
    # Scatter combinado
    fig.add_trace(
        go.Scatter(x=df['duration_minutes'], y=df['max_memory_mb'],
                   mode='markers+text', text=df['step'],
                   textposition='top center',
                   marker=dict(size=df['cpu_percent']/5, color=df['cpu_percent'],
                              colorscale='Viridis', showscale=True,
                              colorbar=dict(title="CPU %", x=1.15)),
                   name='Recursos',
                   hovertemplate='<b>%{text}</b><br>Tiempo: %{x:.1f} min<br>Memoria: %{y:.0f} MB<extra></extra>'),
        row=2, col=2
    )
    
    fig.update_xaxes(title_text="Paso", row=1, col=1, tickangle=-45)
    fig.update_xaxes(title_text="Paso", row=1, col=2, tickangle=-45)
    fig.update_xaxes(title_text="Paso", row=2, col=1, tickangle=-45)
    fig.update_xaxes(title_text="Duración (min)", row=2, col=2)
    
    fig.update_yaxes(title_text="Minutos", row=1, col=1)
    fig.update_yaxes(title_text="MB", row=1, col=2)
    fig.update_yaxes(title_text="%", row=2, col=1)
    fig.update_yaxes(title_text="Memoria (MB)", row=2, col=2)
    
    fig.update_layout(
        title_text="Dashboard de recursos del pipeline",
        height=800,
        showlegend=False,
        template='plotly_white'
    )
    
    fig.write_html(f"{output_dir}/04_resource_dashboard.html")
    print("✓ Gráfico 4: Dashboard de recursos")

def plot_dstat_timeseries(metrics_dir, output_dir):
    """Gráficos de series de tiempo de métricas del sistema"""
    dstat_files = list(Path(metrics_dir).glob("*_dstat.csv"))
    
    if not dstat_files:
        print("⚠ No se encontraron archivos dstat")
        return
    
    for dstat_file in dstat_files:
        step_name = dstat_file.stem.replace('_dstat', '')
        df = load_dstat_data(str(dstat_file))
        
        if df is None or df.empty:
            continue
        
        # Crear gráfico de series de tiempo
        fig = make_subplots(
            rows=3, cols=1,
            subplot_titles=(f'{step_name} - CPU', f'{step_name} - Memoria', f'{step_name} - Disco'),
            vertical_spacing=0.1
        )
        
        # CPU
        if 'usr' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['usr'], name='User CPU', mode='lines', line=dict(color='blue')),
                row=1, col=1
            )
        if 'sys' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['sys'], name='System CPU', mode='lines', line=dict(color='red')),
                row=1, col=1
            )
        
        # Memoria
        if 'used' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['used']/1024/1024, name='Memoria usada', mode='lines', line=dict(color='orange')),
                row=2, col=1
            )
        
        # Disco
        if 'read' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['read']/1024, name='Lectura', mode='lines', line=dict(color='green')),
                row=3, col=1
            )
        if 'writ' in df.columns:
            fig.add_trace(
                go.Scatter(y=df['writ']/1024, name='Escritura', mode='lines', line=dict(color='purple')),
                row=3, col=1
            )
        
        fig.update_yaxes(title_text="% CPU", row=1, col=1)
        fig.update_yaxes(title_text="MB", row=2, col=1)
        fig.update_yaxes(title_text="MB/s", row=3, col=1)
        
        fig.update_layout(
            title_text=f"Métricas en tiempo real - {step_name}",
            height=800,
            template='plotly_white'
        )
        
        safe_name = step_name.replace('/', '_')
        fig.write_html(f"{output_dir}/timeseries_{safe_name}.html")
    
    print(f"✓ Gráficos de series de tiempo: {len(dstat_files)} archivos procesados")

def create_index_html(output_dir):
    """Crear índice HTML con todos los gráficos"""
    html_files = sorted([f for f in os.listdir(output_dir) if f.endswith('.html') and f != 'index.html'])
    
    html_content = """
<!DOCTYPE html>
<html>
<head>
    <title>Performance Report - QIIME2 Pipeline</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }
        h2 {
            color: #34495e;
            margin-top: 30px;
        }
        .graph-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .graph-card {
            background: white;
            border-radius: 8px;
            padding: 15px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: transform 0.2s;
        }
        .graph-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
        }
        .graph-card h3 {
            margin-top: 0;
            color: #2980b9;
        }
        .graph-card a {
            display: inline-block;
            margin-top: 10px;
            padding: 8px 16px;
            background-color: #3498db;
            color: white;
            text-decoration: none;
            border-radius: 4px;
        }
        .graph-card a:hover {
            background-color: #2980b9;
        }
        iframe {
            width: 100%;
            height: 600px;
            border: 1px solid #ddd;
            border-radius: 4px;
            margin: 10px 0;
        }
    </style>
</head>
<body>
    <h1>📊 Performance Report - QIIME2 Pipeline</h1>
    <p>Proyecto: <strong>""" + os.path.basename(os.path.dirname(output_dir)) + """</strong></p>
    <p>Generado: <strong>""" + pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S') + """</strong></p>
    
    <h2>Resúmenes Generales</h2>
    <div class="graph-grid">
"""
    
    # Agregar gráficos principales
    main_plots = [f for f in html_files if f.startswith('0')]
    for plot_file in main_plots:
        plot_name = plot_file.replace('.html', '').replace('_', ' ').title()
        html_content += f"""
        <div class="graph-card">
            <h3>{plot_name}</h3>
            <a href="{plot_file}" target="_blank">Ver en pantalla completa →</a>
            <iframe src="{plot_file}"></iframe>
        </div>
"""
    
    html_content += """
    </div>
    
    <h2>Series de Tiempo por Paso</h2>
    <div class="graph-grid">
"""
    
    # Agregar series de tiempo
    timeseries_plots = [f for f in html_files if f.startswith('timeseries_')]
    for plot_file in timeseries_plots:
        step_name = plot_file.replace('timeseries_', '').replace('.html', '').replace('_', ' ').title()
        html_content += f"""
        <div class="graph-card">
            <h3>{step_name}</h3>
            <a href="{plot_file}" target="_blank">Ver en pantalla completa →</a>
            <iframe src="{plot_file}"></iframe>
        </div>
"""
    
    html_content += """
    </div>
</body>
</html>
"""
    
    with open(f"{output_dir}/index.html", 'w') as f:
        f.write(html_content)
    
    print("✓ Índice HTML creado")

def main():
    if len(sys.argv) != 4:
        print("Usage: python generate_plots.py <logs_dir> <metrics_dir> <output_dir>")
        sys.exit(1)
    
    logs_dir = sys.argv[1]
    metrics_dir = sys.argv[2]
    output_dir = sys.argv[3]
    
    timing_file = f"{logs_dir}/timing_summary.csv"
    
    print("\nGenerando gráficos de rendimiento...")
    print("=" * 50)
    
    # Cargar datos
    df_timing = load_timing_data(timing_file)
    
    # Generar gráficos
    plot_timing_summary(df_timing, output_dir)
    plot_memory_usage(df_timing, output_dir)
    plot_cpu_usage(df_timing, output_dir)
    plot_resource_comparison(df_timing, output_dir)
    plot_dstat_timeseries(metrics_dir, output_dir)
    
    # Crear índice
    create_index_html(output_dir)
    
    print("=" * 50)
    print(f"\n✓ Gráficos generados en: {output_dir}")
    print(f"\nAbrir en navegador: {output_dir}/index.html")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

# ============================================================================
# EJECUTAR SCRIPT PYTHON
# ============================================================================

echo "Generando gráficos..."

/opt/conda/bin/conda run -n qiime2 python "$PLOTS_DIR/generate_plots.py" \
  "$LOGS_DIR" \
  "$METRICS_DIR" \
  "$PLOTS_DIR"

if [[ $? -eq 0 ]]; then
  echo ""
  echo "=========================================="
  echo "✓ Gráficos generados exitosamente"
  echo "=========================================="
  echo ""
  echo "Ubicación: $PLOTS_DIR"
  echo ""
  echo "Para visualizar, abra en su navegador:"
  echo "  $PLOTS_DIR/index.html"
  echo ""
  echo "Gráficos disponibles:"
  ls -1 "$PLOTS_DIR"/*.html | xargs -n 1 basename
  echo ""
else
  echo "ERROR: Falló la generación de gráficos"
  exit 1
fi