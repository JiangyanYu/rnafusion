process ARRIBA_VISUALISATION {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container 'docker://uhrigs/arriba:2.5.0'

    input:
    tuple val(meta) , path(bam), path(bai), path(fusions)
    tuple val(meta2), path(gtf)
    tuple val(meta3), path(protein_domains)
    tuple val(meta4), path(cytobands)

    output:
    tuple val(meta), path("*.pdf"), emit: pdf
    path "versions.yml"           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args                = task.ext.args   ?: ''
    def arg_cytobands       = cytobands       ? " --cytobands=$cytobands"           : ""
    def arg_alignment       = bam             ? " --alignments=$bam"                : ""
    def arg_protein_domains = protein_domains ? "--proteinDomains=$protein_domains" : ""
    def prefix              = task.ext.prefix ?: "${meta.id}"
    """
    draw_fusions.R \\
        --fusions=$fusions \\
        --output=${prefix}.pdf \\
        --annotation=${gtf} \\
        $arg_alignment \\
        $arg_cytobands \\
        $arg_protein_domains \\
        $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        arriba: \$(arriba -h | grep 'Version:' 2>&1 |  sed 's/Version:\s//')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.pdf
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        arriba: \$(arriba -h | grep 'Version:' 2>&1 |  sed 's/Version:\s//')
    END_VERSIONS
    """
}
