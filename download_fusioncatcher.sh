
ensembl_version="115"
params_genome="GRCh38"
human_version="v102"

## better download it with cable connected environment, otherwise takes forever

#wget http://sourceforge.net/projects/fusioncatcher/files/data/human_${human_version}.tar.gz.aa
#wget http://sourceforge.net/projects/fusioncatcher/files/data/human_${human_version}.tar.gz.ab
#wget http://sourceforge.net/projects/fusioncatcher/files/data/human_${human_version}.tar.gz.ac
#wget http://sourceforge.net/projects/fusioncatcher/files/data/human_${human_version}.tar.gz.ad
cat human_${human_version}.tar.gz.* | tar xz
rm human_${human_version}.tar*