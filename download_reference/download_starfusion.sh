
ensembl_version="115"
params_genome="GRCh38"
human_version="v102"

wget https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/__genome_libs_StarFv1.10/GRCh38_gencode_v37_CTAT_lib_Mar012021.plug-n-play.tar.gz --no-check-certificate

tar xvf GRCh38_gencode_v37_CTAT_lib_Mar012021.plug-n-play.tar.gz

rm GRCh38_gencode_v37_CTAT_lib_Mar012021.plug-n-play.tar.gz

mv */ctat_genome_lib_build_dir .