#'@title CrisprSet class
#'@description A container for holding a set of narrowed alignments, 
#'each corresponding to the same target region.  Individual samples are 
#'represented as CrisprRun objects.  CrisprRun objects with no on-target
#'reads are excluded.
#'@param crispr.runs A list of CrisprRun objects, typically representing individual samples
#'within an experiment
#'@param reference The reference sequence, must be the same length as the target region
#'@param target The target location (GRanges).  Variants will be counted over this region.
#'Need not correspond to the guide sequence.  
#'@param rc Should the alignments be reverse complemented, 
#'i.e. displayed w.r.t the reverse strand? (default: FALSE)
#'@param short.cigars If TRUE, variants labels are created from the location of their
#'insertions and deletions.  For variants with no insertions or deletions, the locations 
#'of any single base mismatches are displayed (default: TRUE).
#'@param names A list of names for each of the samples, e.g. for displaying in plots.
#'If not supplied, the names of the crispr.runs are used, which default to the filenames 
#'of the bam files if available (Default: NULL)
#'@param renumbered Should the variants be renumbered using target.loc as the zero point? 
#'If TRUE, variants are described by the location of their 5'-most base with respect to the 
#'target.loc.  A 3bp deletion starting 5bp 5' of the cut site would be labelled
#'(using short.cigars) as -5:3D (Default: TRUE)
#'@param target.loc The location of the Cas9 cut site with respect to the supplied target.
#'(Or some other central location).  Can be displayed on plots and used as the zero point 
#'for renumbering variants. For a target region with the PAM location from bases 21-23, 
#'the target.loc is base 18 (default: NA)
#'@param match.label Label for sequences with no variants (default: "no variant")
#'@param mismatch.label Label for sequences with only single nucleotide variants 
#'  (default: "SNV")
#'@param split.snv Should single nucleotide variants (SNVs) be shown for 
#' reads without an insertion or deletion? (default: TRUE)
#'@param upstream.snv  If split.snv = TRUE, how many bases upstream of the target.loc
#' should SNVs be shown?  (default: 8)
#'@param downstream.snv If split.snv = TRUE, how many bases downstream of the target.loc
#' should SNVs be shown? (default: 5)
#'@param verbose If true, prints information about initialisation progress (default: TRUE)
#'@field crispr_runs A list of CrisprRun objects, typically corresponding to samples 
#'of an experiment.  
#'@field ref The reference sequence for the target region, as a DNAString object 
#'@field cigar_freqs A matrix of counts for each variant
#'@field target The target location, as a GRanges object
#'@author Helen Lindsay
#'@seealso \code{\link[crispRvariants]{CrisprRun}}
#'@export CrisprSet
#'@exportClass CrisprSet 
CrisprSet = setRefClass(
  Class = "CrisprSet",
  fields = c(crispr_runs = "list", 
             ref = "DNAString",
             insertion_sites = "data.frame",
             cigar_freqs = "matrix",
             target = "GRanges",
             genome_to_target = "integer",
             pars = "list")
)

CrisprSet$methods(
  initialize = function(crispr.runs, reference, target, rc = FALSE, short.cigars = TRUE, 
                        names = NULL, renumbered = TRUE, target.loc = NA, 
                        match.label = "no variant", mismatch.label = "SNV",
                        split.snv = TRUE, upstream.snv = 8, downstream.snv = 5,
                        verbose = TRUE, ...){
    
    print(sprintf("Initialising CrisprSet with %s samples", length(crispr.runs)))
    
    reference <- as(reference, "DNAString")
    if (width(target) != length(reference)){
      stop("The target and the reference sequence must be the same width")
    }
    if (renumbered == TRUE & is.na(target.loc)){
      stop(paste0("Must specify target.loc for renumbering variant locations.\n",
                  "The target.loc is the zero point with respect to the reference string.\n",
                  "This is typically 18 for a 23 bp Crispr-Cas9 guide sequence"))
    }
    
    target <<- target   
    ref <<- reference 
    pars <<- list("match_label" = match.label, "target.loc" = target.loc, 
                  "mismatch_label" = mismatch.label, "renumbered" = renumbered)
    
    #pars <<- modifyList(pars, ...)   
    
    crispr_runs <<- crispr.runs
    
    if (is.null(names)) {
      names(.self$crispr_runs) <- sapply(.self$crispr_runs, function(x) x$name)
    }else {
      names(.self$crispr_runs) <- names
    }
    nonempty_runs <- sapply(.self$crispr_runs, function(x) {
      ! length(x$alns) == 0})
    
    .self$crispr_runs <<- .self$crispr_runs[nonempty_runs]
    if (length(.self$crispr_runs) == 0) stop("no on target reads in any sample")
    
    if (verbose == TRUE) cat("Renaming cigar strings\n")
    cig_by_run <- .self$.setCigarLabels(renumbered = renumbered, target.loc = target.loc,
                                        target_start = start(target), target_end = end(target), 
                                        rc = rc, match_label = match.label, 
                                        mismatch_label = mismatch.label, ref = ref, 
                                        short = short.cigars, split.snv = split.snv)
    if (verbose == TRUE) cat("Counting variant combinations\n")
    .self$.countCigars(cig_by_run)
  },
  
  show = function(){
    cat(sprintf(paste0("CrisprSet object containing %s CrisprRun samples\n", 
                         "Target location:\n"), length(.self$crispr_runs)))
    print(.self$target)
    print("Most frequent variants:")
    print(.self$.getFilteredCigarTable(top_n = 6))
  },
  
  .setCigarLabels = function(renumbered = FALSE, target.loc = NA, target_start = NA,
                             target_end = NA, rc = FALSE, match_label = "no variant",
                             mismatch_label = "SNV", short = TRUE, split.snv = TRUE,
                             upstream.snv = 8, downstream.snv = 5, ref = NULL){
    g_to_t <- NULL
    
    if (renumbered == TRUE){
      if (any(is.na(c(target_start, target_end, rc)))){
        stop("Must specify target.loc (cut site), target_start, target_end and rc
             for renumbering")
      }
      g_to_t <- genomeToTargetLocs(target.loc, target_start, target_end, rc)
      }
    cut.site <- ifelse(is.na(target.loc), 18, target.loc)
    
    # This part should be sped up
    cig_by_run <- lapply(.self$crispr_runs,
                         function(crun) crun$getCigarLabels(short = short,
                                            match_label = match_label, 
                                            target_start = target_start,
                                            target_end = target_end,
                                            mismatch_label = mismatch_label,
                                            rc = rc, genome_to_target = g_to_t,
                                            ref = ref, cut.site = cut.site,
                                            split_non_indel = split.snv,
                                            upstream = upstream.snv, 
                                            downstream = downstream.snv))   
    
    return(cig_by_run)
  }, 
  
  .countCigars = function(cig_by_run = NULL, nonvar_first = TRUE){
    # Note that this function does not consider starts, two alignments starting at
    # different locations but sharing a cigar string are considered equal
    
    if (is.null(cig_by_run)){
      cig_by_run <- lapply(.self$crispr_runs, function(crun) crun$getCigarLabels())
    }
    
    unique_cigars <- unique(unlist(cig_by_run))  
    
    m <- matrix(unlist(lapply(cig_by_run, function(x) table(x)[unique_cigars])), 
                nrow = length(unique_cigars), 
                dimnames = list(unique_cigars, names(.self$crispr_runs)))
    
    m[is.na(m)] <- 0
    m <- m[order(rowSums(m), decreasing = TRUE),, drop = FALSE]
    
    if (nonvar_first){    
      is_ref <- grep(.self$pars["match_label"], rownames(m))
      is_snv <- grep(.self$pars["mismatch_label"], rownames(m))
      new_order <- setdiff(1:nrow(m), c(is_ref,is_snv))
      m <- m[c(is_ref, is_snv, setdiff(1:nrow(m), c(is_ref,is_snv))),,drop = FALSE]
    }
    
    cigar_freqs <<- m
  },
  
  filterUniqueLowQual = function(min_count = 2, max_n = 0, verbose = TRUE){
'
Description:
  Deletes reads containing rare variant combinations and more than 
  a minimum number of ambiguity characters within the target region.
  These are assumed to be alignment errors.

Input parameters:
  min_count:    the number of times a variant combination must occur across 
                all samples to keep (default: 2, i.e. a variant must occur
                at least twice in one or more samples to keep)
  max_n:        maximum number of ambiguity ("N") bases a read with a rare
                variant combination may contain.  (default: 0)
  verbose:      If TRUE, print the number of sequences removed (default: TRUE)
'  
    # Find low frequency variant combinations, then find the corresponding samples
    low_freq <- .self$cigar_freqs[rowSums(.self$cigar_freqs) < min_count, , drop = FALSE]
    lf_cig_by_run <- apply(low_freq, 2, function(x) names(x)[x != 0])
    lns <- lapply(lf_cig_by_run, length)
    lf_cig_by_run <- lf_cig_by_run[lns > 0]
    
    # Find the corresponding reads, count the ambiguity characters 
    rm_cset <- unlist(lapply(names(lf_cig_by_run), function(name){
      crun <- cset$crispr_runs[[name]]
      get_idxs <- match(lf_cig_by_run[[name]], crun$cigar_labels)
      sqs <- mcols(crun$alns[get_idxs])$seq
      to_remove <- get_idxs[as.numeric(Biostrings::letterFrequency(sqs, "N")) > max_n]
      cset_to_remove <- match(crun$cigar_labels[to_remove], rownames(cset$cigar_freqs)) 
      if (length(to_remove) > 0) crun$removeSeqs(to_remove)
      return(cset_to_remove)
    }))
    if (verbose){
      cat(sprintf("Removing %s rare sequence(s) with ambiguities\n", length(rm_cset)))
    }
    if ( length(rm_cset) > 0){
      .self$field("cigar_freqs", .self$cigar_freqs[-rm_cset,,drop = FALSE])
    }
  },
  
  .getFilteredCigarTable = function(top_n = nrow(.self$cigar_freqs), freq_cutoff = 0){
    rs <- rowSums(.self$cigar_freqs)
    minfreq <- rs >= freq_cutoff
    topn <- rank(-rs) <= top_n
    cig_freqs <- .self$cigar_freqs[minfreq & topn ,, drop = FALSE] 
    return(cig_freqs) 
  },
  
  .getUniqueIndelRanges = function(add_chr = TRUE, add_to_ins = TRUE){
    # Note this only gets the ranges, not the sequences, inserted sequences may differ
    # Returns a GRanges object of all insertions and deletions, with names = variant names
    # if "add_chr" == TRUE, chromosome names start with "chr"
    # if add_to_ins == TRUE, adds one to end of insertions, as required for VariantAnnotation
    
    cig_by_run <- lapply(.self$crispr_runs, function(crun) crun$getCigarLabels())
    all_cigars <- unlist(cig_by_run)
    unique_cigars <- !duplicated(unlist(cig_by_run))  
    
    co <- do.call(c, unlist(lapply(cset$crispr_runs, function(x) x$cigar_ops), 
                            use.names = FALSE))[unique_cigars]    
    idxs <- co != "M"
    
    ir <- do.call(c, unlist(lapply(cset$crispr_runs, function(x) x$genome_ranges), 
                            use.names = FALSE))
    ir <- ir[unique_cigars][idxs]
    names(ir) <- all_cigars[unique_cigars]
    ir <- unlist(ir)
    
    if (add_to_ins){
      ins_idxs <- unlist(co[idxs] == "I")
      end(ir[ins_idxs]) <- end(ir[ins_idxs]) + 1
    }
    
    chrom <- as.character(seqnames(.self$target))
    if (add_chr & ! grepl('^chr', chrom)){
      chrom <- paste0("chr", chrom)
    }
    
    return(GRanges(chrom, ir))
  },
  
  mutationEfficiency = function(snv = c("include","exclude","non_variant"),
                                exclude_cols = NULL){
'
Description:
  Calculates summary statistics for the mutation efficiency, i.e.
  the percentage of reads that contain a variant.  Reads that do not 
  contain and insertion or deletion, but do contain a single nucleotide 
  variant (snv) can be considered as mutated, non-mutated, or not 
  included in efficiency calculations as they are ambiguous.

Input parameters:
  snv:    One of "include" (consider reads with mismatches to be mutated),
          "exclude" (do not include reads with snvs in efficiency calculations),
          and "non_variant" (consider reads with mismatches to be non-mutated).
  exclude_cols:   A list of column indices to exclude from calculation, e.g. if one
                  sample is a control (default: NULL, i.e. include all columns)
Return value:
  A vector of efficiency statistics per sample and overall

'    
    snv <- match.arg(snv)
    freqs <- .self$cigar_freqs
    
    if (length(exclude_cols) > 0){
      freqs <- freqs[,-exclude_cols, drop = FALSE]
    }
    
    is_snv <- grep(.self$pars$mismatch_label, rownames(freqs))
    
    if (snv == "exclude"){
      if (length(is_snv) > 0) freqs <- freqs[-is_snv,,drop = FALSE]
    }
    
    total_seqs <- colSums(freqs)
    not_mutated <- grep(.self$pars$match_label, rownames(freqs))
    if (snv == "non_variant") not_mutated <- c(not_mutated, is_snv)
    
    if (length(not_mutated) > 0) freqs <- freqs[-not_mutated,,drop = FALSE]
    
    mutants <- colSums(freqs)
    mutant_efficiency = mutants/total_seqs * 100
    average <- mean(mutant_efficiency)
    median <- median(mutant_efficiency)
    overall <- sum(mutants)/ sum(total_seqs) * 100
    result <- round(c(mutant_efficiency, average, median, overall),2)
    names(result) <- c(colnames(freqs), "Average","Median","Overall")
    return(result)
  },
  
  classifyVariantsByType = function(){
    # Classifies variants as reference, mismatch, insertion, deletion
    # or insertion+deletion
    vars <- rep(NA, nrow(.self$cigar_freqs))
    is_snv <- grepl(.self$pars$mismatch_label, rownames(.self$cigar_freqs))
    is_ref <- grepl(.self$pars$match_label, rownames(.self$cigar_freqs))
    is_ins <- grepl("I", rownames(.self$cigar_freqs))
    is_del <- grepl("D", rownames(.self$cigar_freqs))
    ins_and_del <- is_ins & is_del
    vars[is_ref] <- .self$pars$match_label
    vars[is_snv] <- .self$pars$mismatch_label
    vars[is_ins] <- "insertion"
    vars[is_del] <- "deletion"
    vars[ins_and_del] <- "insertion/deletion"
    return(vars)
  },
  
  classifyVariantsByLoc = function(txdb, add_chr = TRUE, verbose = TRUE){
  '
Description:
  Uses the VariantAnnotation package to look up the location of the 
  variants.  VariantAnnotation allows multiple classification tags per variant,
  this function returns a single tag.  The following preference order is used:  
  spliceSite > coding > intron > fiveUTR > threeUTR > promoter > intergenic

Input parameters:
  txdb:     A BSgenome transcription database
  add_chr:  Add "chr" to chromosome names to make compatible with UCSC (default: TRUE)
  verbose:  Print progress (default: TRUE)
  
Return value:
  A vector of classification tags, matching the rownames of .self$cigar_freqs 
  (the variant count table)
  '  
    
    if (verbose) cat("Looking up variant locations\n")
    
    stopifnot(require(VariantAnnotation))
    
    gr <- .self$.getUniqueIndelRanges(add_chr)
    locs <- VariantAnnotation::locateVariants(gr, txdb, AllVariants())
    if (verbose == TRUE) cat("Classifying variants\n")  
  
    locs_codes <- paste(seqnames(locs), start(locs), end(locs), sep = "_")
    # Note that all indels have the same range
    indel_codes <- paste(seqnames(gr), start(gr), end(gr), sep = "_")
    indel_to_loc <- lapply(indel_codes, function(x) locs$LOCATION[which(locs_codes == x)]) 
    
    var_levels <- c("spliceSite","coding","intron","fiveUTR","threeUTR","promoter", "intergenic")
    result <- unlist(lapply(indel_to_loc, function(x){
      y <- factor(x,levels = var_levels)
      var_levels[min(as.numeric(y))]}))
    names(result) <- names(gr)                 
    
    classification <- rep("", nrow(.self$cigar_freqs))
    no_var <- grep(.self$pars$match_label, rownames(.self$cigar_freqs))
    classification[no_var] <- .self$pars$match_label
    snv <- grep(.self$pars$mismatch_label, rownames(.self$cigar_freqs))
    classification[snv] <- .self$pars$mismatch_label
    
    ord <- match(names(result), rownames(.self$cigar_freqs))
    classification[ord] <- result
    names(classification) <- rownames(.self$cigar_freqs)
    
    return(classification)    
  },
  
  classifyCodingBySize = function(var_type, cutoff = 10){
    # This is a naive classification of variants as frameshift or in-frame
    # Coding indels are summed, and indels with sum divisible by 3 are 
    # considered frameshift.  Requires a vector of var_type, and only 
    # considers variants where var_type == "coding"
    
    is_coding <- var_type == "coding"
    
    indels <- .self$cigar_freqs[is_coding,,drop = FALSE]
    if (length(indels) > 0){
      
      temp <- lapply(rownames(indels), function(x) strsplit(x, ",")[[1]])
      indel_grp <- rep(c(1:nrow(indels)), lapply(temp, length))
      indel_ln <- rowsum(as.numeric(gsub("^.*:([0-9]+)[DI]", "\\1", unlist(temp))), indel_grp)
      
      inframe <- indel_ln %% 3 == 0
      is_short <- indel_ln < cutoff
      
      indel_grp <- rep(sprintf("inframe indel < %s", cutoff), nrow(indels))
      indel_grp[is_short &! inframe] <- sprintf("frameshift indel < %s", cutoff)
      indel_grp[!is_short & inframe] <- sprintf("inframe indel > %s", cutoff)   
      indel_grp[!is_short & !inframe] <- sprintf("frameshift indel > %s", cutoff)  
      var_type[is_coding] <- indel_grp
    }
    
    return(var_type)
  },
  
  countVariantAlleles = function(counts_t = NULL){
    # Returns counts of variant alleles
    # SNV alleles are not considered variants here
    if (is.null(counts_t)) counts_t <- .self$cigar_freqs
    counts_t <- counts_t[!rownames(counts_t) == .self$pars["match_label"],,drop = FALSE]
    alleles <- colSums(counts_t != 0)    
    return(data.frame(Allele = alleles, Sample = names(alleles)))
  },
  
  heatmapCigarFreqs = function(as_percent = FALSE, x_size = 16, y_size = 16, 
                               x_axis_title = NULL, x_angle = 90,  
                               freq_cutoff = 0, top_n = nrow(.self$cigar_freqs), ...){
    
    cig_freqs <- .getFilteredCigarTable(top_n, freq_cutoff)
    p <- plotFreqHeatmap(cig_freqs, as.percent = as_percent, x.size = x_size, 
                               y.size = y_size, x.axis.title = x_axis_title,
                               x.angle = x_angle, ...)
    return(p)
  },
  
  plotVariants = function(freq_cutoff = 0, top_n = nrow(.self$cigar_freqs), 
                          renumbered = .self$pars["renumbered"], ...){
'
Description:
  Wrapper for crispRvariants:plotAlignments, optionally filters the table 
  of variants, then plots variants with respect to the reference sequence, 
  collapsing insertions and displaying insertion sequences below the plot.

Input parameters:
  freq_cutoff:      i (integer) only plot variants that occur >= i times
                    (default: 0, i.e no frequency cutoff)
  top_n:            n (integer) Plot only the n most frequent variants 
                    (default: plot all)
                    Note that if there are ties in variant ranks, 
                    top_n only includes ties with all members ranking <= top_n    
  renumbered:       If TRUE, the x-axis is numbered with respect to the target 
                    (cut) site.  If FALSE, x-axis shows genomic locations.
                    (default: TRUE)
  ...               additional arguments for plotAlignments

Return value:
  A ggplot2 plot object.  Call "print(obj)" to display  
'    
     
    cig_freqs <- .self$.getFilteredCigarTable(top_n, freq_cutoff)
    
    alns <- .self$makePairwiseAlns(cig_freqs)
    if (!("cigar" %in% colnames(.self$insertion_sites))){
      .self$getInsertions() 
    }
    
    # How should the x-axis be numbered? 
    # Baseline should be numbers, w optional genomic locations
   
    tloc <- ifelse(is.na(.self$pars$target.loc), 17, .self$pars$target.loc)
    if (renumbered == TRUE){
      genomic_coords <- c(start(.self$target):end(.self$target))
      target_coords <- .self$genome_to_target[as.character(genomic_coords)]
      if (as.character(strand(.self$target)) == "-"){
        target_coords <- rev(target_coords)
      }
      xbreaks = which(target_coords %% 5 == 0 | abs(target_coords) == 1)
      target_coords <- target_coords[xbreaks]
      
      p <- plotAlignments(.self$ref, alns = alns, ins_sites = .self$insertion_sites, 
                          xtick_labs = target_coords, xtick_breaks = xbreaks, 
                          target_loc =  tloc, ...)
    } else {
      p <- plotAlignments(.self$ref, alns = alns, ins_sites = .self$insertion_sites, 
                          target_loc =  tloc, ...)    
    }

    return(p)
  },
  
  plotFrequencySpectrum = function(indel_only = TRUE, ...){   
    # ... are args for postageStampPlot
    
    freqs <- cset$cigar_freqs
    if (indel_only){
      toremove <- sprintf("%s|%s", .self$pars$match_label, .self$pars$mismatch_label)
      idxs <- grep(toremove, rownames(cset$cigar_freqs))
      if (length(idxs) > 0) freqs <- cset$cigar_freqs[-idxs,, drop = FALSE]
    }
    freq_df <- data.frame(nsamples = rowSums(freqs > 0), 
                          variants = rowSums(freqs)) 
    
    freqs <- aggregate(rep(1, nrow(freq_df)), by = as.list(freq_df), FUN = table)
    colnames(freqs) <- c("samples", "variants", "occurs")
    freqs$occurs <- as.numeric(freqs$occurs)
    return(postageStampPlot(freqs, ...))
  },
  
  getInsertions = function(with_cigars = TRUE){
    # Used by plotVariants for getting a table of insertions
    
    if (with_cigars == FALSE){
      all_ins <- do.call(rbind, lapply(.self$crispr_runs, function(x) x$insertions))
    } else {
      all_ins <- do.call(rbind, lapply(.self$crispr_runs, function(x) {
        ik <- x$ins_key
        v <- data.frame(ik, x$getCigarLabels()[as.integer(names(ik))])
        v <- v[!duplicated(v),]
        v <- v[order(v$ik),]
        cbind(x$insertions[v[,1],], cigar = v[,2])
      }))
    }
    if (nrow(all_ins) == 0) {
      insertion_sites <<- all_ins
      return()
    }
    insertion_sites <<- all_ins[order(all_ins$start, all_ins$seq),, drop = FALSE]
  },
  
  makePairwiseAlns = function(cig_freqs = .self$cigar_freqs, ...){
    # Get alignments by cigar string, make the alignment for the consensus
    # The short cigars (not renumbered) do not have enough information, 
    # use the full cigars for sorting
    
    cigs <- unlist(lapply(.self$crispr_runs, function(x) cigar(x$alns)), use.names = FALSE)
    cig_labels <- unlist(lapply(.self$crispr_runs, function(x) x$getCigarLabels()), use.names = FALSE)
    
    names(cigs) <- cig_labels # calling by name with duplicates returns the first match
    
    splits <- split(seq_along(cig_labels), cig_labels)
    splits <- splits[match(rownames(cig_freqs), names(splits))]
    
    splits_labels <- names(splits)
    names(splits) <- cigs[names(splits)]
    
    x <- lapply(.self$crispr_runs, function(x) x$alns)
    all_alns <- do.call(c, unlist(x, use.names = FALSE))
    
    seqs <- c()
    starts <- c()
    
    # SOMEWHERE HERE - CONSENSUS SEQ ONLY TAKING ONE SAMPLE?
    
    for (i in seq_along(splits)){
      idxs <- splits[[i]]
      seqs[i] <- consensusString(mcols(all_alns[idxs])$seq)
      start <- unique(start(all_alns[idxs]))
      if (length(start) > 1)
        stop("Sequences with the same cigar string have different starting locations.
             This case is not implemented yet.")  
      starts[i] <- start[1]
    }  
    
    alns <- mapply(seqsToAln, names(splits), seqs, aln_start = starts, 
                   target_start = start(.self$target), target_end = end(.self$target), ...)
    
    names(alns) <- splits_labels
    alns
  },
  
  genomeToTargetLocs = function(target.loc, target_start, target_end, rc = FALSE){
    # target.loc should be relative to the start of the target sequence, even if the 
    # target is on the negative strand
    # target.loc is the left side of the cut site (Will be numbered -1)
    # target_start and target_end are genomic coordinates, with target_start < target_end
    # rc: is the target on the negative strand wrt the reference?
    # returns a vector of genomic locations and target locations
    
    # Example:  target.loc = 5
    # Before: 1  2  3  4  5  6  7  8 
    # After: -5 -4 -3 -2 -1  1  2  3
    # Left =  original - target.loc - 1
    # Right = original - target.loc
    
    gs <- min(unlist(lapply(.self$crispr_runs, function(x) start(unlist(x$genome_ranges)))))
    
    all_gen_ranges <- lapply(.self$crispr_runs, function(x) x$genome_ranges)
    
    # Nope - here gives a vector
    #gs_test <- min(start(do.call(c, unlist(all_gen_ranges, use.names = FALSE))))
    #cat(sprintf("testing gs: %s = %s: %s", gs_test, gs, gs_test == unlist(gs, use.names=FALSE)))
    
    ge <- max(unlist(lapply(.self$crispr_runs, function(x) end(unlist(x$genome_ranges)))))
    
    if (rc == TRUE){
      tg <- target_end - (target.loc - 1)
      new_numbering <- rev(c(seq(-1*(ge - (tg -1)),-1), c(1:(tg - gs))))
      names(new_numbering) <- c(gs:ge)
      
    } else {
      tg <- target_start + target.loc - 1
      new_numbering <- c(seq(-1*(tg - (gs-1)),-1), c(1:(ge - tg)))
      names(new_numbering) <- c(gs:ge)
    }
    genome_to_target <<- new_numbering
    new_numbering
  }
)