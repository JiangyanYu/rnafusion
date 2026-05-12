export NXF_PLUGINS_DIR="/home/yu_j/.nextflow/plugins/"

/data/genmedbfx/bfx_tools/nextflow/nextflow-25.10.3-dist run ./rna_fusion \
	-profile docker \
	--input ./rna_fusion/tests/csv/fasq.csv \
	--fusioncatcher_ref /home/schilling_m1/Bioinformatics/rnafusion/FusionCatcher/human_v102 \
	--arriba_ref_blacklist /home/schilling_m1/Bioinformatics/rnafusion/blacklist_hg38_GRCh38_v2.5.0.tsv.gz \
	--arriba_ref_cytobands /home/schilling_m1/Bioinformatics/rnafusion/cytobands_hg38_GRCh38_v2.5.0.tsv.gz \
	--arriba_ref_known_fusions /home/schilling_m1/Bioinformatics/rnafusion/known_fusions_hg38_GRCh38_v2.5.0.tsv.gz \
	--arriba_ref_protein_domains /home/schilling_m1/Bioinformatics/rnafusion/protein_domains_hg38_GRCh38_v2.5.0.tsv.gz \

