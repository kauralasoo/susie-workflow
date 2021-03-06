// qtl_subset	count_matrix	pheno_meta	sample_meta	vcf	phenotype_list	covariates
Channel.fromPath(params.qtl_results)
    .ifEmpty { error "Cannot find any qtl_results file in: ${params.qtl_results}" }
    .splitCsv(header: true, sep: '\t', strip: true)
    .map{row -> [ row.qtl_subset, file(row.count_matrix), file(row.pheno_meta), file(row.sample_meta), file(row.vcf), file(row.phenotype_list), file(row.covariates)]}
    .set { qtl_results_ch }

process vcf_to_dosage{
    input:
    tuple qtl_subset, file(expression_matrix), file(phenotype_meta), file(sample_meta), file(vcf), file(phenotype_list), file(covariates) from qtl_results_ch

    output:
    tuple qtl_subset, file(expression_matrix), file(phenotype_meta), file(sample_meta), file(vcf), file(phenotype_list), file(covariates), file("${vcf.simpleName}.dose.tsv.gz"), file("${vcf.simpleName}.dose.tsv.gz.tbi") into susie_input_ch

    script:
    if(params.vcf_genotype_field == 'DS'){
        """
        #Extract header
        printf 'CHROM\\nPOS\\nREF\\nALT\\n' > 4_columns.tsv
        bcftools query -l ${vcf} > sample_list.tsv
        cat 4_columns.tsv sample_list.tsv > header.tsv
        csvtk transpose header.tsv -T | gzip > header_row.tsv.gz

        #Extract dosage and merge
        bcftools query -f "%CHROM\\t%POS\\t%REF\\t%ALT[\\t%DS]\\n" ${vcf} | gzip > dose_matrix.tsv.gz
        zcat header_row.tsv.gz dose_matrix.tsv.gz | bgzip > ${vcf.simpleName}.dose.tsv.gz
        tabix -s1 -b2 -e2 -S1 ${vcf.simpleName}.dose.tsv.gz
        """
    } else if (params.vcf_genotype_field == 'GT'){
        """
        #Extract header
        printf 'CHROM\\nPOS\\nREF\\nALT\\n' > 4_columns.tsv
        bcftools query -l ${vcf} > sample_list.tsv
        cat 4_columns.tsv sample_list.tsv > header.tsv
        csvtk transpose header.tsv -T | gzip > header_row.tsv.gz

        #Extract dosage and merge
        bcftools +dosage ${vcf} -- -t GT | tail -n+2 | gzip > dose_matrix.tsv.gz
        zcat header_row.tsv.gz dose_matrix.tsv.gz | bgzip > ${vcf.simpleName}.dose.tsv.gz
        tabix -s1 -b2 -e2 -S1 ${vcf.simpleName}.dose.tsv.gz
        """
    } 
}

process run_susie{

    input:
    tuple qtl_subset, file(expression_matrix), file(phenotype_meta), file(sample_meta), file(vcf), file(phenotype_list), file(covariates), file(genotype_matrix), file(genotype_matrix_index) from susie_input_ch
    each batch_index from 1..params.n_batches

    output:
    tuple qtl_subset, file("${qtl_subset}.${batch_index}_${params.n_batches}.txt"), file("${qtl_subset}.${batch_index}_${params.n_batches}.cred.txt"), file("${qtl_subset}.${batch_index}_${params.n_batches}.snp.txt") into finemapping_ch

    script:
    """
    Rscript $baseDir/bin/run_susie.R --expression_matrix ${expression_matrix}\
     --phenotype_meta ${phenotype_meta}\
     --sample_meta ${sample_meta}\
     --phenotype_list ${phenotype_list}\
     --covariates ${covariates}\
     --genotype_matrix ${genotype_matrix}\
     --chunk '${batch_index} ${params.n_batches}'\
     --cisdistance ${params.cisdistance}\
     --out_prefix '${qtl_subset}.${batch_index}_${params.n_batches}'\
     --eqtlutils ${params.eqtlutils}\
     --permuted ${params.permuted}
    """
}

process merge_susie{
    publishDir "${params.outdir}/susie_full/", mode: 'copy', pattern: "*.cred.txt.gz"
    publishDir "${params.outdir}/susie_full/", mode: 'copy', pattern: "*.snp.txt.gz"

    input:
    tuple qtl_subset, file(in_cs_variant_batch_names), file(credible_set_batch_names), file(variant_batch_names) from finemapping_ch.groupTuple(size: params.n_batches)

    output:
    tuple qtl_subset, file("${qtl_subset}.txt.gz"), file("${qtl_subset}.cred.txt.gz"), file("${qtl_subset}.snp.txt.gz") into susie_merged_ch

    script:
    """
    awk 'NR == 1 || FNR > 1{print}' ${in_cs_variant_batch_names.join(' ')} | bgzip -c > ${qtl_subset}.txt.gz
    awk 'NR == 1 || FNR > 1{print}' ${credible_set_batch_names.join(' ')} | bgzip -c > ${qtl_subset}.cred.txt.gz
    awk 'NR == 1 || FNR > 1{print}' ${variant_batch_names.join(' ')} | bgzip -c > ${qtl_subset}.snp.txt.gz
    """
}

process sort_susie{
    publishDir "${params.outdir}/susie/", mode: 'copy', pattern: "*.purity_filtered.txt.gz"

    input:
    tuple qtl_subset, file(merged_susie_output), file(susie_cred_output), file(susie_snp_output) from susie_merged_ch

    output:
    tuple qtl_subset, file("${qtl_subset}.purity_filtered.txt.gz") into susie_sorted_ch

    script:
    """
    gunzip -c ${merged_susie_output} > susie_merged.txt
    (head -n 1 susie_merged.txt && tail -n +2 susie_merged.txt | sort -k3 -k4n ) | bgzip > ${qtl_subset}.purity_filtered.txt.gz
    """
}

workflow.onComplete { 
	println ( workflow.success ? "Done!" : "Oops ... something went wrong" )
}

