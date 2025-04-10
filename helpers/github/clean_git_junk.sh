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

backup_dir=""

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
    echo "⚙️  Salvando URL do remote origin..."
    origin_url=$(git remote get-url origin 2>/dev/null || echo "")
    echo "$origin_url" > .origin_backup_url.tmp
    git remote remove origin 2>/dev/null || true

    echo "⚙️  Rodando git-filter-repo com segurança..."
    git filter-repo \
      --invert-paths \
      $(for junk in "${junk_list[@]}"; do echo --path-glob="$junk"; done)

    verify_head

    restored_url=$(cat .origin_backup_url.tmp 2>/dev/null || echo "")
    rm -f .origin_backup_url.tmp

    if [[ -n "$restored_url" ]]; then
      git remote add origin "$restored_url"
      echo "🔄 Remote origin restaurado: $restored_url"

      current_branch=$(git symbolic-ref --short HEAD)
      echo "🔗 Configurando tracking entre '$current_branch' e 'origin/$current_branch'..."
      git branch --set-upstream-to=origin/"$current_branch" "$current_branch" || true
    else
      echo "⚠️  Nenhuma URL de remote encontrada. Você precisará configurar o origin manualmente."
    fi

    echo "✅ Histórico reescrito com sucesso."
  else
    echo "❌ Reescrita do histórico cancelada."
  fi
else
  echo "⏭️  Reescrita do histórico ignorada."
fi

### Push final com proteções e instruções
read -p "Deseja enviar as mudanças para o repositório remoto com 'git push --force-with-lease'? (s/n): " do_push
if [[ "$do_push" == "s" ]]; then
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  remote_url=$(git config --get remote.origin.url)

  if [[ -z "$remote_url" ]]; then
    echo "⚠️  Nenhum remote origin configurado. Vamos configurar agora..."
    read -p "Informe a URL do repositório remoto: " new_remote
    git remote add origin "$new_remote"
    remote_url="$new_remote"
    echo "✅ Remote origin configurado para: $remote_url"
  fi

  echo "📤 Enviando mudanças com sobrescrita segura para '$current_branch'..."
  echo "⚠️  ATENÇÃO: Este push irá sobrescrever o histórico remoto da branch '$current_branch'."
  echo "   Certifique-se de que outros colaboradores estejam cientes."

  read -p "Confirmar push com '--force-with-lease'? (s/n): " confirm_push
  if [[ "$confirm_push" == "s" ]]; then
    git push --force-with-lease origin "$current_branch" || {
      echo "⚠️  Push falhou. Tentando configurar upstream..."
      git push --set-upstream origin "$current_branch"
    }

    echo "✅ Push realizado com sucesso."

    ### Pergunta se deseja excluir backup
    if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
      read -p "Deseja excluir o backup criado em '$backup_dir'? (s/n): " remove_backup
      if [[ "$remove_backup" == "s" ]]; then
        rm -rf "$backup_dir"
        echo "🗑️  Backup excluído com sucesso."
      else
        echo "💾 Backup mantido em: $backup_dir"
      fi
    fi

    echo
    echo "📢 Importante: avise aos colaboradores que o histórico da branch '$current_branch' foi reescrito."
    echo "🔁 Eles devem executar os seguintes comandos para evitar conflitos:"
    echo
    echo "   git fetch origin"
    echo "   git checkout $current_branch"
    echo "   git reset --hard origin/$current_branch"
    echo
  else
    echo "🚫 Push cancelado."
  fi
else
  echo "🚫 Push cancelado pelo usuário."
fi

echo
echo "🎉 Processo concluído com segurança."
echo "👉 Próximos passos:"
echo "   • Se você reescreveu o histórico, avise seus colaboradores."
echo "   • Se não fez push ainda, use 'git push --force-with-lease'."
echo "   • Revise se o .gitignore cobre todos os arquivos indesejados."

### Verificação tardia do .gitignore
for junk in "${junk_list[@]}"; do
  if ! grep -qxF "$junk" .gitignore 2>/dev/null; then
    echo "⚠️  Aviso: '$junk' não está listado no .gitignore"
    echo "   → Considere adicioná-lo para evitar reversionamento futuro."
  fi
done

if [[ -n "$backup_dir" ]]; then
  echo "   • Se o backup foi mantido, ele está em: $backup_dir"
fi
