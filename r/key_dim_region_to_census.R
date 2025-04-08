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

# 1. Import ---------------------------------------------------------------

# QuintoAndar Dim Region with spatial features
# Replication in parquet file of dim_region.rds archive used in For Rent Index
# Ref: rppi-production r package
sf_dim_region <- sfarrow::st_read_parquet(
  here::here("data", "1_raw", "quinto_andar", "geo_dim_region.parquet")
)

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
sf_key_dim_region <- sf_dim_region %>%
  sf::st_simplify(dTolerance = 100) %>%
  sf::st_transform(crs = 4674) %>%
  # Only key columns
  dplyr::distinct(sk_region, geometry)

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

# 3. Test --------------------------------------------------------------

# Invalid geometries must be equal to zero
sum(!sf::st_is_valid(sf_key_dim_region)) == 0
sum(!sf::st_is_valid(sf_key_census_weighting_area)) == 0
sum(!sf::st_is_valid(sf_key_census_tract)) == 0

# 4. Integrate --------------------------------------------------------------------

# Custom function to join spatial features with largest intersection efficiently
spatial_join_largest <- function(source_sf, target_sf, source_key, target_key, suffix = c(".x", ".y"), left = TRUE) {
  # Load necessary packages
  require(sf)
  require(geos)
  require(dplyr)
  require(vctrs)
  require(tibble)
  
  # Check if both source_sf and target_sf are of class 'sf'
  if (!inherits(source_sf, "sf") | !inherits(target_sf, "sf")) {
    stop("Both source_sf and target_sf must be of class 'sf'.")
  }
  
  # Check for invalid geometries using geos
  source_invalid_geom <- !geos::geos_is_valid(sf::st_geometry(source_sf))
  target_invalid_geom <- !geos::geos_is_valid(sf::st_geometry(target_sf))
  
  # Stop the process if there are invalid geometries
  if (any(source_invalid_geom)) {
    stop("Some geometries in source_sf are invalid. Please fix them before proceeding.")
  }
  
  if (any(target_invalid_geom)) {
    stop("Some geometries in target_sf are invalid. Please fix them before proceeding.")
  }
  
  # Perform the spatial join using 'geos' intersection matrix
  keys <- geos::geos_intersects_matrix(source_sf, target_sf)
  
  # Check if there are any intersections
  has_intersections <- lengths(keys) > 0
  
  # If no intersections, we keep the rows from source_sf as they are
  if (!any(has_intersections)) {
    message("No intersections found between the provided geometries.")
    return(source_sf)  # Return source_sf as is if no intersections
  }
  
  # Filter valid keys (intersections)
  valid_keys <- keys[has_intersections]
  
  # Replicate the source keys for each valid intersection
  source_out <- vctrs::vec_rep_each(source_sf[[source_key]][has_intersections], lengths(valid_keys))
  index_list <- unlist(valid_keys)
  
  # Extract the corresponding rows from target_sf based on valid intersections
  target_out <- target_sf[index_list, ]
  
  # Align the geometries (without modifying the original sf objects)
  source_geom <- sf::st_geometry(source_sf)[rep(which(has_intersections), lengths(valid_keys))]
  
  if (length(source_geom) != nrow(target_out)) {
    stop("Geometry misalignment detected.")
  }
  
  # Calculate the intersections using geos
  intersection_geoms <- geos::geos_intersection(source_geom, sf::st_geometry(target_out))
  intersection_areas <- geos::geos_area(intersection_geoms)
  
  # Create a dataframe with the intersections and their areas
  intersection_df <- tibble::tibble(
    source_id = source_out,
    target_id = target_out[[target_key]],
    area = intersection_areas
  ) %>% dplyr::filter(area > 0)  # Remove zero-area intersections
  
  # Keep the largest intersection per source_id
  best_matches <- intersection_df %>%
    dplyr::group_by(source_id) %>%
    dplyr::slice_max(area, n = 1, with_ties = FALSE) %>%
    dplyr::ungroup()
  
  # Perform the final join (based on `left` parameter)
  if (left == TRUE) {
    final_join <- best_matches %>%
      dplyr::select(-area) %>%  # Remove the area column
      dplyr::full_join(source_sf, by = c("source_id" = source_key), suffix = suffix) %>% # Full join source_sf columns
      dplyr::left_join(st_drop_geometry(target_sf), by = c("target_id" = target_key), suffix = suffix) %>% # Join target_sf columns
      dplyr::rename(!!source_key := source_id, !!target_key := target_id)  # Rename id columns
    
  } else {
    final_join <- best_matches %>%
      dplyr::select(-area) %>%  # Remove the area column
      dplyr::left_join(source_sf, by = c("source_id" = source_key), suffix = suffix) %>% # Left join source_sf columns
      dplyr::left_join(st_drop_geometry(target_sf), by = c("target_id" = target_key), suffix = suffix) %>% # Join target_sf columns
      dplyr::rename(!!source_key := source_id, !!target_key := target_id)  # Rename id columns
  }
  
  # Convert the result_sf to a standard data frame, if necessary, and return as 'sf'
  result <- sf::st_as_sf(as.data.frame(final_join))
  
  # Return the result
  return(result)
}

# Apply function to join dim_region to both census_weighting_area and to census_tract
key_dim_region_to_census <- list(sf_key_census_tract, sf_key_census_weighting_area) %>%
  purrr::map2(
    .x = .,
    .y = c("cd_setor", "code_weighting"),
    .f = ~ spatial_join_largest(
      source_sf = sf_key_dim_region, 
      target_sf = .x, 
      source_key = "sk_region", 
      target_key = .y,
      left = TRUE,
      suffix = c("", "_ibge")
    )
  ) %>%
  # Drop the geometry column from the resulting dataframes
  purrr::map(st_drop_geometry) %>%
  # Reduce the list of dataframes into a single dataframe
  purrr::reduce(full_join) 


# 5. Export ------------------------------------------------------------------

# Export to local directory
arrow::write_parquet(
  key_dim_region_to_census,
  here::here("data", "2_cleaned",
             "key_dim_region_to_census.parquet")
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

# Export to DBFS
upload_to_dbfs(
  key_dim_region_to_census,
  filename = "key_dim_region_to_census.parquet",
  dbfs_dir = "dbfs:/FileStore/indice_5a/",
  workspace_url = "DATABRICKS_HOST"
)
