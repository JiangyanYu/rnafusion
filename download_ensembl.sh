
ensembl_version="115"
params_genome="GRCh38"

wget https://ftp.ensembl.org/pub/release-${ensembl_version}/fasta/homo_sapiens/dna/Homo_sapiens.${params_genome}.dna.chromosome.{1..22}.fa.gz
wget https://ftp.ensembl.org/pub/release-${ensembl_version}/fasta/homo_sapiens/dna/Homo_sapiens.${params_genome}.dna.chromosome.{MT,X,Y}.fa.gz

wget https://ftp.ensembl.org/pub/release-${ensembl_version}/gtf/homo_sapiens/Homo_sapiens.${params_genome}.${ensembl_version}.gtf.gz
wget https://ftp.ensembl.org/pub/release-${ensembl_version}/gtf/homo_sapiens/Homo_sapiens.${params_genome}.${ensembl_version}.chr.gtf.gz
wget https://ftp.ensembl.org/pub/release-${ensembl_version}/fasta/homo_sapiens/cdna/Homo_sapiens.${params_genome}.cdna.all.fa.gz -O Homo_sapiens.${params_genome}.${ensembl_version}.cdna.all.fa.gz

gunzip -c Homo_sapiens.${params_genome}.dna.chromosome.* > Homo_sapiens.${params_genome}.${ensembl_version}.all.fa
gunzip Homo_sapiens.${params_genome}.${ensembl_version}.gtf.gz
gunzip Homo_sapiens.${params_genome}.${ensembl_version}.chr.gtf.gz

rm Homo_sapiens.${params_genome}.dna.chromosome.*