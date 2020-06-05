#!/usr/local/bin/perl

# compare-vcf2bam.pl
# (c) 2020 Ed Green / UC Regents
# Compares a VCF file of genotypes generated by deep-sequencing or
# other means to the information in a bam file.
# Determines where the individual in the bam file might have 0, 1, or 2
# IBD segments.

use Vcf;
use Getopt::Std;
use vars qw( $opt_V $opt_B $opt_Q $opt_a $opt_I $opt_v $opt_D );
use strict;

my $VERSION = 3.1;
my %BASES = ( 'A' => 1, 'C' => 1, 'G' => 1, 'T' => 1 );
my %Nchoosek = (1 => { 0 => 1, 1 => 1 },
		2 => { 0 => 1, 1 => 2, 2 =>1 },
		3 => { 0 => 1, 1 => 3, 2 =>3, 3 => 1 },
		4 => { 0=>1, 1=>4, 2=>6, 3=>4 , 4 => 1 },
		5 => { 0=>1, 1=>5, 2=>10, 3=>10, 4=>5, 5=>1 },
		6 => { 0=>1, 1=>6, 2=>15, 3=>20, 4=>15, 5=>6, 6=>1 },
		7 => { 0=>1, 1=>7, 2=>21, 3=>35, 4=>35, 5=>21, 6=>7, 7=>1 },
		8 => { 0=>1, 1=>8, 2=>28, 3=>56, 4=>70, 5=>56, 6=>28, 7=>8, 8=>1 },
		9 => { 0=>1, 1=>9, 2=>36, 3=>84, 4=>126, 5=>126, 6=>84, 7=>36, 
		       8=>9, 9=>1 },
		10 =>{ 0=>1, 1=>10, 2=>45, 3=>120, 4=>210, 5=>252, 6=>210, 
		       7=>120, 8=>45, 9=>10, 10=>1 },
		11 =>{ 0=>1, 1=>11, 2=>55, 3=>165, 4=>330, 5=>462, 6=>462, 
		       7=>330, 8=>165, 9=>55, 10=>11, 11=>1 },
		12 =>{ 0=>1, 1=>12, 2=>66, 3=>220, 4=>495, 5=>792, 6=>924, 
		       7=>792, 8=>495, 9=>220, 10=>66, 11=>12, 12=>1 }
    );
		
my ($vcf_o) = &init();
my $EPSILON = 0.02;
my $MAX_REAL_COV = 20;
my $mean_depth;

# $pos2data_p => { POS => 
#                  [REF, ALT, rsID, AF, GQ, DP, A0, A1, #REF, #ALT], ...
#  for all positions that pass filters
my ($pos2data_p, $chr) = &RArsAFA0A1_VCF( $vcf_o );
&add_bam( $pos2data_p, $chr );
$mean_depth = &output_depth_dist( $pos2data_p );
if ( defined( $opt_D ) ) {
    &cull_depth( $pos2data_p, $mean_depth, $opt_D );
    printf( "# Depth after culling to %.2f\n", $opt_D );
    $mean_depth = &output_depth_dist( $pos2data_p );
}
&output_table( $pos2data_p );


# Populate the REF, ALT, rsID, AF, A0, and A1 fields from
# an input VCF file. Use only bi-allelic sites that pass
# the $opt_Q genotype quality filter
sub RArsAFA0A1_VCF {
    my $vcf_o = shift;
    my %pos2data;
    my ($l, $chr, $pos, $rsid, $ref, $alt, $gtq, $dp, $filter,
	$info, $format, $gt, $info_p, $format_p, $af, $A0, $A1);

    while( $l = $vcf_o->next_data_array ) {
	$chr    = $l->[0];
	$pos    = $l->[1];
	$rsid   = $l->[2];
	$ref    = $l->[3];
	$alt    = $l->[4];
	$gtq    = $l->[5];
	$filter = $l->[6];
	$info   = $l->[7];
	$format = $l->[8];
	$gt     = $vcf_o->get_column( $l, $opt_I );

	if ( ($gtq >= $opt_Q) &&
	     &biallelic( $ref, $alt ) ) {
	    $info_p   = &parse_info( $info );
	    $format_p = &parse_format( $format, $gt );
	    if ( $info_p->{'AF'} ) {
		$af = $info_p->{'AF'};
	    }
	    else {
		$af = 0.01;
	    }
	    $dp = $info_p->{'DP'};
	    if ( $format_p->{'GT'} ) {
		if ( $format_p->{'GT'} =~ /\// ) {
		    ($A0, $A1) = split( '/', $format_p->{'GT'} );
		}
		elsif ( $format_p->{'GT'} =~ /\|/ ) {
		    ($A0, $A1) = split( '\|', $format_p->{'GT'} );
		}
		else {
		    print STDERR ("Weird GT: ", $format_p->{'GT'}, "\n" );
		    next;
		}
		# Finally, if passed filters and we got a genotype, add it
		unless( $opt_v && ($A0 == 0) && ($A1 == 0) ) {
		    $pos2data{ $pos } = 
			[$ref, $alt, $rsid, $af, $gtq, $dp, $A0, $A1];
		}
	    }
	}
    }
    return (\%pos2data, $chr);
}

sub output_table {
    my $pos2data_p = shift;
    my $p_D_IBD0 = 1; # prob of data given no IBD chromosomes
    my $p_D_IBD1 = 1; # prob of data given one IBD chromosome
    my $p_D_IBD2 = 1; # prob of data given two IBD chromosomes
    print( "# Pos\tREF\tALT\t\trsID\tAF\tGQ\tDP\tVCFA0\tVCFA1\tBAMnREF\tBAMnALT\tL(IBD0)\tL(IBD1)\tL(IBD2)\n" );
    foreach my $pos ( sort { $a <=> $b } keys %{ $pos2data_p } ) {
	$p_D_IBD0 =
	    &find_pDgivenf( $pos2data_p->{$pos}->[8],
			    $pos2data_p->{$pos}->[9],
			    $pos2data_p->{$pos}->[3] );
	
	$p_D_IBD2 = 
	    &find_pDgivenG( $pos2data_p->{$pos}->[6],
			    $pos2data_p->{$pos}->[7],
			    $pos2data_p->{$pos}->[8],
			    $pos2data_p->{$pos}->[9] );
	    
	if ( ($pos2data_p->{$pos}->[6] == 0) &&
	     ($pos2data_p->{$pos}->[7] == 0) ) {
	    # Site is homozygous REF; probability of seeing an ALT
	    # allele is *HALF* it's pop frequency since one chr is
	    # not ALT under the model of IBD1
	    $p_D_IBD1 = &find_pDgivenf( $pos2data_p->{$pos}->[8],
					$pos2data_p->{$pos}->[9],
					($pos2data_p->{$pos}->[3])/2 );
	}
	elsif ( ($pos2data_p->{$pos}->[6] == 0) &&
		($pos2data_p->{$pos}->[7] == 1) ) {
	    # Site is heterozygous; probability of seeing an ALT
	    # allele is composite of whether drawn allele is one
	    # REF or ALT chromosome under model IBD1
	    $p_D_IBD1 = (0.5 * &find_pDgivenf( $pos2data_p->{$pos}->[8],
					       $pos2data_p->{$pos}->[9],
					       ($pos2data_p->{$pos}->[3])/2) )
		+
		(0.5  * &find_pDgivenf( $pos2data_p->{$pos}->[8],
					$pos2data_p->{$pos}->[9],
					($pos2data_p->{$pos}->[3])/2 + 0.5 ));
	}
	elsif ( ($pos2data_p->{$pos}->[6] == 1) &&
		($pos2data_p->{$pos}->[7] == 1) ) {
	    $p_D_IBD1 = &find_pDgivenf( $pos2data_p->{$pos}->[8],
					$pos2data_p->{$pos}->[9],
					($pos2data_p->{$pos}->[3])/2 + 0.5 );
	}
	
	print( join( "\t", 
		     $pos, 
		     @{ $pos2data_p->{$pos} }, 
		     $p_D_IBD0, $p_D_IBD1, $p_D_IBD2 ),
	       "\n" );
    }
}

sub output_depth_dist {
    my $p2d_p = shift;
    my ($pos, $cov, $i );
    my $total_sites = 0;
    my $total_cov   = 0;
    my $cov;
    my @covdist;
    foreach $pos ( keys %{ $p2d_p } ) {
	$cov = $p2d_p->{$pos}->[8] + $p2d_p->{$pos}->[9];
	$covdist[$cov]++;
	$total_sites++;
    }
    printf( "# COVERAGE NUM_SITES\n" );
    for( $i = 0; $i <= $MAX_REAL_COV; $i++ ) {
	printf( "# %d %d\n", $i, $covdist[$i] );
	$total_cov += ($covdist[$i] * $i);
    }
    return $total_cov/$total_sites;
}

sub cull_depth {
    my $p2d_p        = shift;
    my $mean_depth   = shift;
    my $target_depth = shift;
    my $cull_p;
    my $new_ref_count;
    my $new_alt_count;
    my ( $i, $pos );
    if ( $target_depth > $mean_depth ) {
	print STDERR ( "Observed depth of coverage is higher than -D. No culling will be done.\n" );
	return;
    }
    else {
	$cull_p = $target_depth / $mean_depth;
    }

    foreach $pos ( keys %{ $p2d_p } ) {
	# Cull the REF alleles
	$new_ref_count = 0;
	$new_alt_count = 0;
	for( $i = 0; $i < $p2d_p->{$pos}->[8]; $i++ ) {
	    if ( rand() < $cull_p ) {
		# Keep it
		$new_ref_count++;
	    }
	}
	for( $i = 0; $i < $p2d_p->{$pos}->[9]; $i++ ) {
	    if ( rand() < $cull_p ) {
		# Keep it
		$new_alt_count++;
	    }
	}
	$p2d_p->{$pos}->[8] = $new_ref_count;
	$p2d_p->{$pos}->[9] = $new_alt_count;
    }
}
    
sub find_pDgivenf {
    my $nREF = shift; # number of observed reference (0) alleles
    my $nALT = shift; # number of observed alternate (1) alleles
    my $f    = shift; # population frequency of alternate (1) allele
    my $pD = 1;

    # If there are no observed counts, the probability is 1
    if ( ($nREF == 0) && ($nALT == 0) ) {
	return 1;
    }
    
    $pD = 
	# Hardy-Wienberg           P(Data|Genotype)
	#     |                          |
	(1-$f)**2           * &find_pDgivenG( 0, 0, $nREF, $nALT ) +
	2 * (1-$f) * $f     * &find_pDgivenG( 0, 1, $nREF, $nALT ) +
	$f**2               * &find_pDgivenG( 1, 1, $nREF, $nALT );
    return $pD;
}

sub find_pDgivenG {
    my $A0   = shift; # Allele 0 of Genotype
    my $A1   = shift; # Allele 1 of Genotype
    my $nREF = shift; # number of observed reference (0) alleles
    my $nALT = shift; # number of observed alternate (1) alleles
    my $pD = 1;
    # If there are no observed counts, the probability is 1
    if ( ($nREF == 0) && ($nALT == 0) ) {
	return 1;
    }

    # Heterozygous site? If so, probability of drawing either allele
    # is 0.5. So, binomial function with p=0.5
    # (n choose k) x p**k x (1-p)**(n-k)
    # We will arbitrarily choose $nREF to be "Successes". Mathematically,
    # it doesn't matter if we assign $nREF or $nALT to "successes".
    if ( ($nREF + $nALT) <= 12 ) {
	if ( (($A0 == 0) && ($A1 == 1)) ||
	     (($A0 == 1) && ($A1 == 0)) ) {
	    # Here, Epsilon cancels because p = 0.5
	    $pD = $Nchoosek{ $nREF + $nALT }->{ $nREF } *
		0.5**$nREF *
		0.5**$nALT;
	}
	elsif ( ($A0 == 1) && ($A1 == 1) ) {
	    $pD = $Nchoosek{ $nREF + $nALT }->{ $nREF } *
		(1 - $EPSILON)**$nALT * $EPSILON**$nREF;
	}
	elsif ( ($A0 == 0) && ($A1 == 0) ) {
	    $pD = $Nchoosek{ $nREF + $nALT }->{ $nREF } *
		(1 - $EPSILON)**$nREF * $EPSILON**$nALT;
	} 
	else {
	    print STDERR ("WTF: A0 = $A0 & A1 = $A1\n" );
	}
	return $pD;
    }
}

sub add_bam {
    my $pos2data_p = shift;
    my $chr        = shift;
    my ($pos, $cmd, $l, $tmp_N, $REF, $ALT, $a_p);
    my ( @mp );
    
    # Make input regions file for samtools mpileup
    my $tmp_N = int(rand(1000));
    my $TMP_REG_FN = "/tmp/REGIONS.$tmp_N..txt";
    my $TMP_MP     = "/tmp/MP.$tmp_N.txt";
    open( TMP, ">$TMP_REG_FN" ) or die( "$!: $TMP_REG_FN\n" );
    foreach my $pos ( sort { $a <=> $b } keys %{ $pos2data_p } ) {
	print TMP "$chr $pos\n";
    }
    close( TMP );
    
    # Call samtools mpileup
    $cmd = "samtools mpileup -l $TMP_REG_FN -o $TMP_MP -r $chr -A -a -q 30 -Q 30 $opt_B";
    system($cmd);
    
    # parse mpileup, adding to $pos2data_p table
    open( MP, $TMP_MP ) or die( "$!: $TMP_MP\n" );
    while( chomp( $l = <MP> ) ) {
	# parse the mpileup line
	@mp = split( "\t", $l );
	if ( $mp[3] == 0 ) {
	    $pos2data_p->{$mp[1]}->[8] = 0;
	    $pos2data_p->{$mp[1]}->[9] = 0;
	}
	else {
	    $REF = $pos2data_p->{$mp[1]}->[0]; # Find REF allele at this site
	    $ALT = $pos2data_p->{$mp[1]}->[1]; # Find ALT allele at this site
	    $a_p = &pu_allele_counts( \@mp );  # Get allele counts from mpileup
	    $pos2data_p->{$mp[1]}->[8] = $a_p->{$REF}; # Pop number of obs REF
	    $pos2data_p->{$mp[1]}->[9] = $a_p->{$ALT}; # Pop number of obs ALT
	}
    }
    close( MP );
	
    # Clean up by removing tmp file
    system( "rm $TMP_REG_FN" );
    system( "rm $TMP_MP" );
}

### Takes pointer to pileup fields.
### Returns pointer to hash of uc(alleles) as keys and
### counts of those alleles as values.
sub pu_allele_counts {
    my $pu_p = shift; # pointer to pileup fields
    my ( $token, $last_token, $indel_len, $i, $ins_seq, $del_seq );
    my @md_tokens;
    my %alleles = ( 'A' => 0, 'C' => 0, 'G' => 0, 'T' => 0 ); # init counts to 0
    @md_tokens = split('', $pu_p->[4]);

    while( $token = shift(@md_tokens) ) {
        $token = uc( $token );
        if(($token eq '.') or ($token eq ',')) {
            $alleles{$pu_p->[2]}++;
        }
        elsif( $BASES{$token} or ($token eq 'N') ) {
            $alleles{$token}++;
        }

        elsif( $token eq '+' ) {
            $indel_len = 0;
            $token = shift(@md_tokens);
            while($token =~ /\d/) {
                $indel_len *= 10;
                $indel_len += $token;
                $token = shift(@md_tokens);
            }
            $ins_seq = $token;
            for( $i = 1; $i < $indel_len; $i++ ) {
                $ins_seq .= shift(@md_tokens);
            }
            $alleles{$last_token."+$indel_len"}++;
            $alleles{$last_token}--; #We just saw insertion. Previous "allele"
                                # was just announcement this is an insertion
        }

        elsif( $token eq '-' ) {
            $indel_len = 0;
            $token = shift(@md_tokens);
            while( $token =~ /\d/ ) {
                $indel_len *= 10;
                $indel_len += $token;
                $token = shift(@md_tokens);
            }
            $del_seq = $token;
            for( $i = 1; $i < $indel_len; $i++ ) {
                $del_seq .= shift(@md_tokens);
            }
            $alleles{$last_token."-$indel_len"}++;
            $alleles{$last_token}--; # We just saw deletion. Prevous "allele"
                                     # was just announcement this is a deletion
        }
        elsif( $token eq '*' ) {
            ; # This place is deleted in this read => no alleles
        }
        elsif( $token eq '^' ) { # Beginning of a read. So what.
            shift(@md_tokens); # MapQ of this new guy. So what.
            if ( $opt_a > 0 ) { # AncientDNA type flag?
                # remove first base, it could be chemical (aDNA) damage
                if ( $BASES{$md_tokens[0]} ||
                     $md_tokens[0] eq '.'  ||
                     $md_tokens[0] eq ','  ||
                     $md_tokens[0] eq 'N' ) {
                    shift(@md_tokens);
                }
            }
        }
        elsif( $token eq '$' ) {
            ; # just ignore the fact
            # that the last base was the last base of a read.
        }
        else {
            print STDERR ( "Problem parsing pileup token: $token\n" );
            # WTF?
        }
        $last_token = $token;
    }
    return \%alleles;
    }

sub parse_format {
    my $format_string = shift;
    my $gt_string     = shift;
    chomp( $gt_string );
    my $i;
    my ( @fkeys, @fvals );
    my %format;
    @fkeys = split( ':', $format_string );
    @fvals = split( ':', $gt_string );
    for( $i = 0; $i <= $#fkeys; $i++ ) {
	$format{ $fkeys[$i] } = $fvals[$i];
    }
    return \%format;
    }

    
# Returns pointer to hash of INFO field information
# keys are INFO elements, values are their values
# for keys without values, value is set to 1 (TRUE)
    sub parse_info {
    my $info_string = shift;
    my %info;
    my ( $member, $k, $v );
    foreach $member ( split( ';', $info_string ) ) {
	if ( $member =~ /=/ ) {
	    ($k, $v) = split( '=', $member );
	    $info{$k} = $v;
	}
	else {
	    $info{$member} = 1;
	}
    }
    return \%info;
    }

# Returns TRUE IFF both ref and alt are a single, known base
# This is used to check for simple, bi-allelic SNPs
sub biallelic {
    my $ref = shift;
    my $alt = shift;
    if ( $BASES{$ref} && $BASES{$alt} ) {
	return 1;
    }
    return 0;
}
    
sub init {
    my $Q_DEF = 40;
    my $vcf_o;
    my @samples;
    getopts( 'V:B:Q:a:I:D:v' );
    unless( -f $opt_V &&
	    -f $opt_B ) {
	print( "compare-vcf2bam.pl Find 0, 1, or 2 IBD segments between\n" );
	print( "VCF file and bam file info.\n" );
	print( "It is assumed that input is on a single chromosome.\n" );
	print( "This chromosome ID is learned by parsing the VCF file.\n" );
	print( "-V <VCF file>\n" );
	print( "-B <BAM file>\n" );
	print( "-D <downsample to this fold-coverage depth>\n" );
	print( "-Q <Genotype quality minimum; default = $Q_DEF>\n" );
	print( "-a <Remove first base observations>\n" );
	print( "-I <identifier of sample if there are multiple samples in VCF file>\n" );
	print( "-v <if set, make output only for sites that have >=1 variant\n" );
	print( "    allele in VCF genotype for this sample>\n" );
	print( "Format of output table is tab-delimited with columns:\n" );
	print( "Position, REF_ALLELE, ALT_ALLELE, rsID, AF, GenotypeQ, DP, VCFA0, VCFA1, BAMnREF, BAMnALT, P(IBD0), P(IBD1), P(IBD2)\n" );
	exit( 0 );
    }
    unless ( defined( $opt_Q ) ) {
	$opt_Q = $Q_DEF;
    }

    $vcf_o = Vcf->new(file => $opt_V);
    $vcf_o->parse_header();

    # Check and/or set-up $opt_I (the identifier) for the sample in
    # the vcf file we'll use for comparison
    if ( defined( $opt_I ) ) { # user gave a sample ID. Check that it's present
	map { if ($opt_I eq $_) {return $vcf_o;} } $vcf_o->get_samples();
	print STDERR ( "$opt_I not found in VCF file: $opt_V\n" );
	exit( 0 );
    }

    else {
	@samples = $vcf_o->get_samples;
	if ( $#samples == 0 ) {
	    $opt_I = $samples[0];
	    return $vcf_o;
	}
	else {
	    print STDERR ( "You must specify the sample ID via the -I option\n" );
	    exit( 0 );
	}
    }
}