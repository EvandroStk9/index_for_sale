setup_databricks <- function() {
  message("🛠️  Iniciando setup completo do ambiente com suporte a Databricks...\n")
  
  # ───────────────────────────────────────────────
  # Preparar diretórios
  # ───────────────────────────────────────────────
  helpers_dir <- here::here("r", "helpers", "databricks")
  if (!dir.exists(helpers_dir)) dir.create(helpers_dir, recursive = TRUE)
  message("📁 Pasta de helpers: ", helpers_dir)
  
  # ───────────────────────────────────────────────
  # Instalar pacotes R essenciais
  # ───────────────────────────────────────────────
  required_packages <- c("here", "reticulate", "sparklyr", "DBI", "glue")
  to_install <- required_packages[!(required_packages %in% installed.packages()[, "Package"])]
  if (length(to_install) > 0) install.packages(to_install)
  invisible(lapply(required_packages, library, character.only = TRUE))
  
  # ───────────────────────────────────────────────
  # Atualizar .Renviron com variáveis do Databricks
  # ───────────────────────────────────────────────
  renv_path <- here::here(".Renviron")
  vars <- c("DATABRICKS_CLUSTER_ID", "DATABRICKS_HOST", "DATABRICKS_TOKEN")
  env_vars <- Sys.getenv(vars, unset = NA)
  
  missing_vars <- vars[is.na(env_vars)]
  if (length(missing_vars) > 0) {
    message("📝 Atualizando .Renviron com variáveis necessárias do Databricks...")
    if (!file.exists(renv_path)) file.create(renv_path)
    renv_lines <- readLines(renv_path, warn = FALSE)
    for (var in missing_vars) {
      value <- readline(paste0("❓ Informe o valor para ", var, ": "))
      renv_lines <- c(renv_lines, paste0(var, "=", value))
    }
    writeLines(renv_lines, renv_path)
    message("✅ .Renviron atualizado. Reinicie o R para carregar as novas variáveis de ambiente.")
  } else {
    message("✅ Variáveis do Databricks já estão configuradas em .Renviron.")
  }
  
  # ───────────────────────────────────────────────
  # Gerar e executar script bash com pyenv + venv
  # ───────────────────────────────────────────────
  bash_script <- here::here("r", "helpers", "databricks", "install_python_deps.sh")
  writeLines(c(
    "#!/bin/bash",
    "set -e",
    "export PATH=\"$HOME/.pyenv/bin:$PATH\"",
    "eval \"$(pyenv init --path)\"",
    "eval \"$(pyenv init -)\"",
    "echo \"🔍 Verificando pyenv...\"",
    "if ! command -v pyenv &> /dev/null; then",
    "  echo \"❌ pyenv não encontrado. Instale manualmente.\"",
    "  exit 1",
    "fi",
    "PYTHON_VERSION=3.10.13",
    "ENV_PATH=\"$HOME/.venvs/databricks\"",
    "if pyenv versions --bare | grep -q \"^$PYTHON_VERSION$\"; then",
    "  echo \"✅ Python $PYTHON_VERSION já instalado.\"",
    "else",
    "  echo \"⬇️  Instalando Python $PYTHON_VERSION...\"",
    "  pyenv install $PYTHON_VERSION",
    "fi",
    "PYTHON_PATH=\"$(pyenv root)/versions/$PYTHON_VERSION/bin/python\"",
    "echo \"🧹 Limpando ambiente virtual existente...\"",
    "rm -rf \"$ENV_PATH\"",
    "echo \"🐍 Criando novo virtualenv...\"",
    "$PYTHON_PATH -m venv \"$ENV_PATH\"",
    "source \"$ENV_PATH/bin/activate\"",
    "pip install --upgrade pip",
    "pip install databricks-cli",
    "cat <<EOF > r/helpers/databricks/requirements_databricks_conn.txt",
    "databricks-connect==13.3.*",
    "pandas>=1.0.0",
    "pyarrow>=10.0.0",
    "protobuf<=3.20.3",
    "EOF",
    "pip install -r r/helpers/databricks/requirements_databricks_conn.txt",
    "echo \"✅ Dependências Python instaladas.\""
  ), bash_script)
  Sys.chmod(bash_script, "0755")
  message("🐚 Executando: ", bash_script)
  result <- system(paste("bash", bash_script), intern = TRUE)
  cat(paste(result, collapse = "\n"), "\n")
  
  # ───────────────────────────────────────────────
  # Atualizar .Rprofile
  # ───────────────────────────────────────────────
  rprofile_path <- here::here(".Rprofile")
  rprofile_line <- 'reticulate::use_virtualenv("~/.venvs/databricks", required = TRUE)'
  if (!file.exists(rprofile_path)) file.create(rprofile_path)
  rprofile_content <- readLines(rprofile_path)
  if (!any(grepl("use_virtualenv\\(", rprofile_content))) {
    new_block <- c(
      'if (requireNamespace("reticulate", quietly = TRUE)) {',
      paste0("  try({ ", rprofile_line, " }, silent = TRUE)"),
      '}',
      ""
    )
    writeLines(c(new_block, rprofile_content), rprofile_path)
    message("📝 .Rprofile atualizado com suporte ao virtualenv.")
  } else {
    message("✅ .Rprofile já contém configuração de virtualenv.")
  }
  
  # ───────────────────────────────────────────────
  # Finalização
  # ───────────────────────────────────────────────
  message("\n✅ Setup completo finalizado!")
  message("🚨 Reinicie a sessão do R para aplicar tudo corretamente.")
}

# Function to upload parquet file to Databricks DBFS
upload_to_dbfs <- function(df, filename, dbfs_dir = "dbfs:/FileStore/indice_5a/", workspace_url = NULL) {
  # Load required packages
  require(arrow)
  require(glue)
  require(here)
  
  # 1. save locally using `here()` (saves in the project directory)
  local_path <- here::here(filename)
  arrow::write_parquet(df, local_path, compression = "snappy")
  
  # 2. detect Databricks CLI
  cli_path <- Sys.which("databricks")
  if (cli_path == "") stop("❌ A CLI do Databricks não foi encontrada no PATH do sistema.")
  
  # 3. assure R sees the CLI path
  current_path <- Sys.getenv("PATH")
  cli_dir <- dirname(cli_path)
  if (!grepl(cli_dir, current_path, fixed = TRUE)) {
    Sys.setenv(PATH = paste(current_path, cli_dir, sep = .Platform$path.sep))
  }
  
  # 4. mount DBFS path securely
  dbfs_path <- paste0(dbfs_dir, ifelse(endsWith(dbfs_dir, "/"), "", "/"), filename)
  
  # 5. Build command to upload the file to DBFS
  cmd <- glue::glue('databricks fs cp "{local_path}" "{dbfs_path}" --overwrite')
  result <- tryCatch({
    system(cmd, intern = TRUE)
  }, error = function(e) {
    stop("❌ Erro ao executar o comando CLI: ", e$message)
  })
  
  # 6. feedback in the console
  cat("✅ Upload concluído!\n")
  cat(result, sep = "\n")
  
  # 7. generate web link if possible
  if (!is.null(workspace_url)) {
    url <- gsub("dbfs:/FileStore", paste0(workspace_url, "/files"), dbfs_path)
    cat("\n🔗 Acesse via:\n", url, "\n")
  } else {
    cat("\nℹ️ Passe o argumento `workspace_url` para gerar o link direto no navegador.\n")
  }
  
  # 8. invisible return
  invisible(list(local = local_path, dbfs = dbfs_path))
}
