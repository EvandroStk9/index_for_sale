# 0. Setup ---------------------------------------------------------------

# To guarantee gdal dependencies required for the sf package
#system('sudo apt-get install -y libudunits2-dev libgdal-dev libgeos-dev libproj-dev libjq-dev libprotobuf-dev protobuf-compiler')

# To guarantee no scientific notation
options(scipen = 99999999)

# Packages required
packages <- c(
  "here", "sf", "tidyverse",
  "geobr", "janitor", "sparklyr", "DBI"
)

# Packages installed
packages_installed <- data.frame(
  packages = packages,
  installed = packages %in% rownames(installed.packages())
) 

# Install required packages if necessary 
if (any(packages %in% packages_installed$installed == FALSE)) {
  install.packages(packages[!packages_installed$installed])
}

# Import packages
invisible(lapply(packages, library, character.only = TRUE))

# Connect IDE to Databricks
databricks_conn <- sparklyr::spark_connect(
  method = "databricks_connect",
  #cluster_id = Sys.getenv("DATABRICKS_CLUSTER_ID")
  cluster_id = "0130-201321-d8g2hbrk"
)

# 1. Import ---------------------------------------------------------------


# Get id's from houses used in the For Sale Index
query_key_sale_listings <- "
SELECT DISTINCT
  sk_house,
  lng,
  lat
FROM quintoandar_prod.data_house.sale_listings
WHERE lng IS NOT NULL -- anomaly cleaning
  AND lat IS NOT NULL -- anomaly cleaning
"

# Key with sale listings and their coordinates
# It will be enriched with census data
key_sale_listings <-  DBI::dbGetQuery(databricks_conn, query_key_sale_listings) 

# Get 2010 brazilian Census weighting areas
sf_census_weighting_area <- geobr::read_weighting_area() %>%
  janitor::clean_names()

# Get 2022 brazilian Census tracts
# Downloaded from: https://www.ibge.gov.br/estatisticas/sociais/trabalho/22827-censo-demografico-2022.html?=&t=downloads
# Censo_Demografico_2022/Agregados_por_Setores_Censitarios/malha_com_atributos/setores/gpkg/BR
path_sf_census_tract <- "https://ftp.ibge.gov.br/Censos/Censo_Demografico_2022/Agregados_por_Setores_Censitarios/malha_com_atributos/setores/gpkg/BR/BR_setores_CD2022.gpkg"
sf_census_tract <- sf::st_read(path_sf_census_tract) %>%
  janitor::clean_names()

# 2. Transform -----------------------------------------------------------------

# Transform dataframe into spatial object
sf_key_sale_listings<- sf::st_as_sf(
  key_sale_listings,
  coords = c("lng", "lat"),
  crs = 4326
) %>%
  # Reproject CRS
  sf::st_transform(crs = 4674)


# Clean weighting areas data
sf_key_census_weighting_area <- sf_census_weighting_area %>%
  # Make valid (silently) and keep only successful conversions
  { 
    valid <- suppressWarnings(sf::st_make_valid(.))
    valid[sf::st_is_valid(valid), ]
  } %>%
  # Simplify with auto-fallback
  tryCatch(
    expr = sf::st_simplify(dTolerance = 100),
    error = function(e) {
      warning("Simplification failed - returning valid geometries unsimplified")
      .
    }
  ) %>%
  # Only key columns
  dplyr::distinct(code_weighting, geom)

# Clean cleaned census tracts data
sf_key_census_tract <- sf_census_tract %>%
  # Make valid (silently) and keep only successful conversions
  {
    valid <- suppressWarnings(sf::st_make_valid(.))
    valid[sf::st_is_valid(valid), ]
  } %>%
  # Simplify with auto-fallback
  tryCatch(
    expr = sf::st_simplify(dTolerance = 100),
    error = function(e) {
      warning("Simplification failed - returning valid geometries unsimplified")
      .
    }
  ) %>%
  # Only key columns
  dplyr::distinct(cd_setor, geom)

# 3. Test --------------------------------------------------------------------

# Invalid geometries must be equal to zero
sum(!sf::st_is_valid(sf_key_sale_listings)) == 0
sum(!sf::st_is_valid(sf_key_census_weighting_area)) == 0
sum(!sf::st_is_valid(sf_key_census_tract)) == 0

# 4. Integrate --------------------------------------------------------------------

# Get key from sale index houses to census by data integration
# Data joined by spatial features and return dataframe
key_sale_listings_to_census <- sf_key_sale_listings %>%
  sf::st_join(sf_key_census_tract, join = sf::st_nearest_feature) %>%
  sf::st_join(sf_key_census_weighting_area, join = sf::st_nearest_feature) %>%
  sf::st_drop_geometry()

# 5. Export ------------------------------------------------------------------

#
arrow::write_parquet(
  key_sale_listings_to_census,
  here::here("data", "2_cleaned",
             "key_sale_listings_to_census.parquet")
)

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


# Upload to Databricks DBFS
upload_to_dbfs(
  df = key_sale_listings_to_census,
  filename = "key_sale_listings_to_census.parquet",
  dbfs_dir = "dbfs:/FileStore/indice_5a/",
  workspace_url = Sys.getenv("DATABRICKS_HOST")
)
