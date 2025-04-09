#!/bin/bash
set -e

JUNK_PATHS=(
  ".DS_Store"
  "Icon?"
  "Thumbs.db"
  "*.swp"
  "*.swo"
)

echo "🧹 Limpando arquivos indesejados do diretório..."
for pattern in "${JUNK_PATHS[@]}"; do
  find . -name "$pattern" -exec rm -f {} + 2>/dev/null || true
done
echo "✅ Arquivos indesejados removidos."

# Checa se estão no .gitignore
if [[ -f .gitignore ]]; then
  echo "🔍 Verificando se arquivos junk estão no .gitignore..."
  for entry in "${JUNK_PATHS[@]}"; do
    if ! grep -qxF "$entry" .gitignore; then
      echo "⚠️ Atenção: '$entry' não está listado no .gitignore"
    fi
  done
else
  echo "⚠️ Nenhum .gitignore encontrado no diretório atual."
fi

# Limpa arquivos do index (sem apagar localmente)
echo "📦 Limpando arquivos do index Git (se existirem)..."
git rm -r --cached "${JUNK_PATHS[@]}" 2>/dev/null || true

# Commit da limpeza
echo "📌 Commit da limpeza..."
git commit -am "chore: remove arquivos indesejados" || echo "Nada para commitar."

# Limpeza básica de referências e objetos antes do rewrite
echo "🧽 Rodando git gc e fsck antes da reescrita..."
git reflog expire --expire=now --all
git gc --aggressive --prune=now
git fsck --full

# Confirmação
echo "🚨 ATENÇÃO: Isso vai reescrever TODO o histórico do Git."
read -p "Tem certeza que quer continuar? (s/n): " confirm
[[ "$confirm" != "s" ]] && echo "❌ Cancelado." && exit 1

# Verifica git-filter-repo
if ! command -v git-filter-repo &> /dev/null; then
  echo "❌ git-filter-repo não encontrado. Instale com:"
  echo "   brew install git-filter-repo  # (macOS)"
  echo "   ou: https://github.com/newren/git-filter-repo"
  exit 1
fi

# Salva remote
origin_url=$(git remote get-url origin 2>/dev/null || true)

# Lista branches remotas
branches_remotas=$(git branch -r | grep -v 'HEAD' | sed 's|origin/||' | sort -u)

# Remove referências problemáticas relacionadas a 'Icon' (com qualquer byte suspeito)
echo "🧼 Procurando e removendo referências relacionadas a 'Icon' (inclusive com caracteres invisíveis)..."
find .git/refs -type f | while IFS= read -r ref; do
  if hexdump -C "$ref" | grep -iq 'Icon'; then
    echo "   → Deletando referência suspeita: $ref"
    rm -f "$ref"
  fi
done

find .git/logs/refs -type f | while IFS= read -r logref; do
  if hexdump -C "$logref" | grep -iq 'Icon'; then
    echo "   → Deletando log de referência suspeita: $logref"
    rm -f "$logref"
  fi
done

git remote prune origin || true

# Reescreve o histórico com git-filter-repo
echo "🧨 Reescrevendo histórico com git-filter-repo..."
for path in "${JUNK_PATHS[@]}"; do
  args+=(--path "$path")
done

git filter-repo --force --invert-paths "${args[@]}"

# Restaura origin se removido
if ! git remote get-url origin &> /dev/null && [[ -n "$origin_url" ]]; then
  echo "🔁 Restaurando remote origin: $origin_url"
  git remote add origin "$origin_url"
fi

# Limpa arquivos não rastreados
echo "🧹 Limpando arquivos não rastreados..."
git clean -xfd

# Push forçado
echo "📤 Fazendo push forçado das branches locais..."
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  git push origin --force "$branch"
done

# Remove branches remotas órfãs
echo "🧨 Deletando branches remotas órfãs..."
for remote_branch in $branches_remotas; do
  if ! git show-ref --verify --quiet "refs/heads/$remote_branch"; then
    echo "   → Deletando do remoto: $remote_branch"
    git push origin --delete "$remote_branch" || true
  fi
done

# Push de tags
echo "🏷️ Fazendo push forçado das tags..."
git push origin --force --tags

echo "✅ Limpeza completa! Histórico e repositório atualizados com sucesso."
