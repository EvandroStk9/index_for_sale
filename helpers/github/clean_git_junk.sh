#!/bin/bash

set -e

echo "🧹 Iniciando processo de limpeza do repositório Git com segurança..."

junk_list=(
  ".DS_Store"
  "Icon?"
  "Thumbs.db"
  "*.swp"
  "*.swo"
)

### Função auxiliar para backup completo
backup_repo() {
  backup_dir="../$(basename "$PWD")-backup-$(date +%Y%m%d-%H%M%S)"
  echo "💾 Criando backup completo do repositório em: $backup_dir"
  git clone --mirror . "$backup_dir"
  echo "✅ Backup criado com sucesso."
}

### Verificação de HEAD válida
verify_head() {
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "❌ HEAD inválido. O repositório pode estar corrompido. Abortando..."
    exit 1
  fi
}

### Remoção de arquivos do sistema
echo "🔍 Removendo arquivos indesejados do diretório..."
for junk in "${junk_list[@]}"; do
  find . -name "$junk" -exec rm -f {} + 2>/dev/null && echo "   → Removido: $junk"
done
echo "✅ Arquivos indesejados removidos."

### Limpeza do index Git
echo "📦 Limpando arquivos do index Git (se versionados)..."
for junk in "${junk_list[@]}"; do
  git rm --cached -r "$junk" 2>/dev/null || true
done
echo "✅ Index limpo."

### Verifica mudanças para commit
if [[ -n $(git status --porcelain) ]]; then
  echo "📝 Mudanças detectadas:"
  git status -s

  read -p "Deseja realizar um commit dessas mudanças? (s/n): " do_commit
  if [[ "$do_commit" == "s" ]]; then
    read -p "Informe a mensagem do commit [default: 'chore: remove arquivos indesejados']: " commit_msg
    commit_msg=${commit_msg:-"chore: remove arquivos indesejados"}
    git commit -am "$commit_msg"
    echo "✅ Commit realizado."
  else
    echo "⚠️  Mudanças não foram commitadas."
  fi
else
  echo "📭 Nenhuma mudança para commit."
fi

### Reescrever histórico
read -p "Deseja reescrever o histórico com git-filter-repo para remoção completa de junk antigo? (s/n): " rewrite_history
if [[ "$rewrite_history" == "s" ]]; then
  backup_repo

  echo "🧼 Rodando git gc e fsck antes da reescrita..."
  git gc --prune=now
  git fsck --full

  echo "🚨 Isso irá reescrever TODO o histórico do Git."
  read -p "Tem certeza que deseja continuar? (s/n): " confirm
  if [[ "$confirm" == "s" ]]; then
    echo "⚙️  Rodando git-filter-repo com segurança..."
    git filter-repo \
      --invert-paths \
      $(for junk in "${junk_list[@]}"; do echo "--path-glob '$junk' "; done)

    verify_head

    # Restaura remote origin
    remote_url=$(git config --get remote.origin.url)
    if [[ -n "$remote_url" ]]; then
      git remote add origin "$remote_url" 2>/dev/null || true
      echo "🔄 Remote origin restaurado: $remote_url"
    fi

    echo "✅ Histórico reescrito com sucesso."
  else
    echo "❌ Reescrita do histórico cancelada."
  fi
else
  echo "⏭️  Reescrita do histórico ignorada."
fi

### Verifica se os arquivos estão no .gitignore
echo "🧾 Verificando se os arquivos junk estão no .gitignore..."
for junk in "${junk_list[@]}"; do
  if ! grep -qxF "$junk" .gitignore 2>/dev/null; then
    echo "⚠️  Atenção: '$junk' não está listado no .gitignore"
  fi
done

### Push final
read -p "Deseja enviar as mudanças para o repositório remoto com 'git push --force-with-lease'? (s/n): " do_push
if [[ "$do_push" == "s" ]]; then
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  echo "📤 Enviando mudanças com sobrescrita segura..."
  git push --force-with-lease origin "$current_branch" || {
    echo "⚠️  Push falhou. Tentando configurar upstream..."
    git push --set-upstream origin "$current_branch"
  }
else
  echo "🚫 Push cancelado."
fi

echo "🎉 Processo concluído com segurança. Repositório limpo e íntegro!"
