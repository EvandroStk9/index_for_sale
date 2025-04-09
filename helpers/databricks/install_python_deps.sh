#!/bin/bash
set -e
export PATH="$HOME/.pyenv/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
echo "🔍 Verificando pyenv..."
if ! command -v pyenv &> /dev/null; then
  echo "❌ pyenv não encontrado. Instale manualmente."
  exit 1
fi
PYTHON_VERSION=3.10.13
ENV_PATH="$HOME/.venvs/databricks"
if pyenv versions --bare | grep -q "^$PYTHON_VERSION$"; then
  echo "✅ Python $PYTHON_VERSION já instalado."
else
  echo "⬇️  Instalando Python $PYTHON_VERSION..."
  pyenv install $PYTHON_VERSION
fi
PYTHON_PATH="$(pyenv root)/versions/$PYTHON_VERSION/bin/python"
echo "🧹 Limpando ambiente virtual existente..."
rm -rf "$ENV_PATH"
echo "🐍 Criando novo virtualenv..."
$PYTHON_PATH -m venv "$ENV_PATH"
source "$ENV_PATH/bin/activate"
pip install --upgrade pip
cat <<EOF > r/helpers/databricks/requirements_databricks_conn.txt
databricks-connect==13.3.*
pandas>=1.0.0
pyarrow>=10.0.0
protobuf<=3.20.3
EOF
pip install -r r/helpers/databricks/requirements_databricks_conn.txt
echo "✅ Dependências Python instaladas."
