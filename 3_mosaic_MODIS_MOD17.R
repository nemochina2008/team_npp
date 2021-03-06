###############################################################################
# Mosaics MODIS MOD17 (1000m NPP) product to 
# cover the spatial extent of the ZOI/CSA/PA boundary of each team site.
# 
# Requires a GDAL installation that supports HDF4 files - on Windows, see 
# OSGEO4W to meet this dependency.
###############################################################################

library(rgdal)
library(raster)
library(stringr)
library(gdalUtils)
library(rgeos)
library(gfcanalysis) # for utm_zone

library(doParallel)
library(foreach)

n_cpus <- 4
overwrite <- TRUE

registerDoParallel(n_cpus)

zoi_folder <- '/localdisk/home/azvoleff/ZOI_CSA_PAs'
in_base_dir <- '/localdisk/home/azvoleff/MODIS_NPP'
out_base_dir <- '/localdisk/home/azvoleff/MODIS_NPP'
in_folder <- file.path(in_base_dir, 'ORIGINALS')
out_folder <- file.path(in_base_dir, 'ZOI_Crops')

hdfs <- dir(in_folder, pattern='.hdf$')
tile_key <- read.csv('TEAM_Site_MODIS_Tiles.csv')
sitecodes <- unique(tile_key$sitecode)

n <- 1
for (sitecode in sitecodes) {
    message(paste0('Processing ', sitecode, ' (', n, ' of ',
                   length(sitecodes), ').'))
    site_rows <- tile_key[tile_key$sitecode == sitecode, ]
    tile_ids <- paste0('h', sprintf('%02i', site_rows$h),
                       'v', sprintf('%02i', site_rows$v))

    load(file.path(zoi_folder, paste0(sitecode, '_ZOI_CSA_PA.RData')))
    aoi <- gConvexHull(aois)
    aoi <- spTransform(aoi, CRS(utm_zone(aoi, proj4string=TRUE)))
    aoi <- gBuffer(aoi, width=5000)

    t_srs <- proj4string(aoi)
    te <- as.numeric(bbox(aoi))

    tile_regex <- paste(paste0('(', tile_ids, ')'), collapse='|')
    tiles <- hdfs[grepl(tile_regex, hdfs)]
    if (length(tiles) == 0) {
        stop('no tiles found')
    }
    product <- gsub('[.]', '', str_extract(tiles, '^[a-zA-Z0-9]*[.]'))
    if (length(unique(product)) != 1) {
        stop('tiles are from more than one MODIS product')
    }
    product <- product[1]

    dates <- unique(as.Date(str_extract(tiles, '[0-9]{7}'), '%Y%j'))

    ret <- foreach(this_date=iter(dates),
            .packages=c('raster', 'gdalUtils', 'stringr'), 
            .inorder=FALSE) %dopar% {
        tiles_by_date <- tiles[grepl(format(this_date, '%Y%j'), tiles)]
        srcfiles <- file.path(in_folder, tiles_by_date)
        out_base <- file.path(out_folder,
                              paste(product, sitecode,
                                    format(this_date, '%Y%j'), sep='_'))

        n_subdatasets <- length(get_subdatasets(srcfiles[[1]]))
        for (n in 1:n_subdatasets) {
            subdatasets <- unlist(lapply(srcfiles, function(srcfile) get_subdatasets(srcfile)[[n]]))
            band_names <- gsub(':', '', str_extract(subdatasets, ':[a-zA-Z0-9_]*$'))
            stopifnot(all(band_names == band_names[1]))
            band_name <- band_names[[1]]
            # First build a VRT with all the bands in the HDF file (this mosaics 
            # the tiles, but with delayed computation - the actual mosaicing 
            # computations won't take place until the gdalwarp line below)
            vrt_file <- paste0(out_base, '_', band_name, '_temp.vrt')
            gdalbuildvrt(subdatasets, vrt_file)
    
            dstfile <- paste0(out_base, '_', band_name, '.tif')
            # Mosaic, reproject, and crop vrt
            gdalwarp(vrt_file, dstfile, t_srs=t_srs, te=te, tr=c(1000, 1000),
                     r='cubicspline', overwrite=overwrite,
                     of="GTiff")
    
            # Delete the temp files
            unlink(vrt_file)
        }
    }
    n <- n + 1
}
