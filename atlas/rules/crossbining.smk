### VAMB


localrules:
    combine_contigs,
    vamb,


rule vamb:
    input:
        "Crossbinning/vamb/clustering",



rule filter_contigs:
    input:
        "{sample}/{sample}_contigs.fasta"
    output:
        "Crossbinning/filtered_contigs/{sample}.fasta.gz"

    params:
        min_length= config['cobining_min_contig_length']
    log:
        "log/Crossbinning/filter_contigs/{sample}.log"
    conda:
        "../envs/required_packages.yaml"
    threads: config.get("simplejob_threads", 1)
    resources:
        mem=config["simplejob_mem"],
        java_mem=int(int(config["simplejob_mem"] * JAVA_MEM_FRACTION)),
    shell:
        " reformat.sh in={input} "
        " fastaminlen={params.min_length} "
        " out={output} "
        " overwrite=true "
        " threads={threads} "
        " -Xmx{resources.java_mem}G 2> {log} "




localrules: combine_contigs
rule combine_contigs:
    input:
        ancient(expand("Crossbinning/filtered_contigs/{sample}.fasta.gz", sample=SAMPLES)),
    output:
        "Crossbinning/combined_contigs.fasta.gz",
    log:
        "log/crossbining/combine_contigs.log",
    threads: 1
    run:
        from utils.io import cat_files
        cat_files(input, output[0])


rule minimap_index:
    input:
        contigs=rules.combine_contigs.output,
    output:
        mmi=temp("Crossbinning/combined_contigs.mmi"),
    params:
        index_size="12G",
    resources:
        mem=config["large_mem"],
    threads: 1
    log:
        "log/crossbinning/vamb/index.log",
    benchmark:
        "log/benchmarks/crossbining/mminimap_index.tsv"
    conda:
        "../envs/minimap.yaml"
    shell:
        "minimap2 -I {params.index_size} -d {output} {input} 2> {log}"


rule samtools_dict:
    input:
        contigs=rules.combine_contigs.output,
    output:
        dict="Crossbinning/mapping/combined_contigs.dict",
    resources:
        mem=config["simplejob_mem"],
    threads: 1
    log:
        "log/crossbining/samtools_dict.log",
    conda:
        "../envs/minimap.yaml"
    shell:
        "samtools dict {input} | cut -f1-3 > {output} 2> {log}"


rule minimap:
    input:
        fq=lambda wildcards: input_paired_only(
            get_quality_controlled_reads(wildcards)
        ),
        mmi="Crossbinning/combined_contigs.mmi",
        dict="Crossbinning/combined_contigs.dict",
    output:
        bam=temp("Crossbinning/mapping/{sample}.unsorted.bam"),
    threads: config["threads"]
    resources:
        mem=config["mem"],
    log:
        "log/crossbining/mapping/{sample}.minimap.log",
    benchmark:
        "log/benchmarks/crossbining/mminimap/{sample}.tsv"
    conda:
        "../envs/minimap.yaml"
    shell:
        """minimap2 -t {threads} -ax sr {input.mmi} {input.fq} | grep -v "^@" | cat {input.dict} - | samtools view -F 3584 -b - > {output.bam} 2>{log}"""


ruleorder: sort_bam > minimap > convert_sam_to_bam


rule sort_bam:
    input:
        "Crossbinning/mapping/{sample}.unsorted.bam",
    output:
        "Crossbinning/mapping/{sample}.bam",
    params:
        prefix="Crossbinning/mapping/tmp.{sample}",
    threads: 2
    resources:
        mem=config["simplejob_mem"],
        time=int(config["runtime"]["simple_job"]),
    log:
        "log/crossbining/mapping/{sample}.sortbam.log",
    conda:
        "../envs/minimap.yaml"
    shell:
        "samtools sort {input} -T {params.prefix} --threads {threads} -m 3G -o {output} 2>{log}"


rule summarize_bam_contig_depths:
    input:
        bam=expand(rules.sort_bam.output, sample=SAMPLES),
    output:
        "Crossbinning/vamb/coverage.jgi.tsv",
    log:
        "log/crossbinning/vamb/combine_coverage.log",
    conda:
        "../envs/metabat.yaml"
    threads: config["threads"]
    resources:
        mem=config["mem"],
    shell:
        "jgi_summarize_bam_contig_depths "
        " --outputDepth {output} "
        " {input.bam} &> {log} "


localrules:
    convert_jgi2vamb_coverage,


rule convert_jgi2vamb_coverage:
    input:
        "Crossbinning/vamb/coverage.jgi.tsv",
    output:
        "Crossbinning/vamb/coverage.tsv",
    log:
        "log/crossbinning/vamb/convert_jgi2vamb_coverage.log",
    threads: 1
    script:
        "../scripts/convert_jgi2vamb_coverage.py"


rule run_vamb:
    input:
        coverage="Crossbinning/vamb/coverage.tsv",
        fasta=rules.combine_contigs.output,
    output:
        directory("Crossbinning/vamb/clustering"),
    conda:
        "../envs/vamb.yaml"
    threads: 1  #config["threads"]
    resources:
        mem=config["mem"],
        time=config["runtime"]["long"],
    log:
        "log/crossbinning/vamb/run_vamb.log",
    benchmark:
        "log/benchmarks/vamb/run_vamb.tsv"
    params:
        params="-m 2000 --minfasta 500000",
    shell:
        "vamb --outdir {output} "
        " -o '_' "
        " --jgi {input.coverage} "
        " --fasta {input.fasta} "
        " {params.params} "
        "2> {log}"


include: "semibin.smk"
