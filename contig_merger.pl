#!/usr/bin/perl

#contig_merger.pl
#Code by Pedro Ivo Guimaraes, 2016

#Script to merge contigs inside the clusters present in the cluster files generated by
#BBTools Dedupe.sh program using the .dot file and the fasta sequences in clusters.

use warnings;
use strict;
use FastaTools;
use List::Util qw(min max sum);
use List::MoreUtils qw(first_index uniq);
use Array::Utils qw(array_minus);
use File::Basename;
use Getopt::Std;
use Data::Dumper;
use Graph;
use Graph::Traversal::DFS;
use Graph::Reader::Dot;

########################################
#### Declaring command-line options ####
########################################
our($opt_i, $opt_c, $opt_h, $opt_v, $opt_o);
getopts('i:c:hvo:');

#Declaring the options:
my $graph_dot_file 	= $opt_i;
my $cluster_files 	= $opt_c;
my $output_file_prefix 	= $opt_o || "overlap_extended_contigs"; 

#Declaring output files:
my $output_file		= $output_file_prefix.".fasta"; #Output file with all extended contigs
my $info_file		= "info_".$output_file_prefix.".txt"; #Output file with merged contig informations
my $output_file2 	= "selected_".$output_file_prefix.".fasta"; #File with only the contigs with the best path scores
my $info_file2 		= "info_".$output_file2.".txt"; #Information about the selected contigs
my $output_file3 	= "removed_".$output_file_prefix.".fasta"; #File with the "loser" contigs due to their path scores
my $output_file4	= "all_merged_contigs.fasta"; #File with all selected and single contigs. 

#################################
#### Importing cluster files ####
#################################
print "Importing cluster files:\n";
my ($filename_pattern, $path) = fileparse($cluster_files);
$cluster_files =~ tr/%/\*/; #changing the % character for the *, allowing pattern search

my $number_of_cluster_files = `ls $cluster_files | wc -l`;
print "Number of cluster files = $number_of_cluster_files\n"; 

#Creating file with all the clusters' contig sequences:
my $allcontigs_file = $path."allcontigs.fastq";
system("cat $cluster_files > $allcontigs_file") unless -e $allcontigs_file;

#Opening file with all contigs:
my %records = FastaTools::loadfastq($allcontigs_file);
my $total_number_of_contigs = keys %records;
my @contig_lengths = map {length($records{$_}{'seq'})} keys %records;
my %metrics = sequence_metrics(@contig_lengths);

print_metrics(%metrics);

#####################################################
#### Importing and modifying the .dot graph file ####
#####################################################
# We will use the CPAN Graph::Reader module to manipulate the .dot file:
print "Opening graph file: $graph_dot_file\n";
my $dot_reader = Graph::Reader::Dot->new();
my $dot_graph = $dot_reader->read_graph($graph_dot_file);

my $single_contigs_count = $dot_graph->isolated_vertices();
my $all_vertices_count = $dot_graph->vertices;

print "Total number of vertices in graph: $all_vertices_count\n";
print "Number of isolated vertices in graph: $single_contigs_count\n"; 
print "Done!\n\n";

#The first thing we have to do is to reorient the edges in the graph in order to
#make all edges correspond to a contig w/ overlap in the END -> contig w/ overlap in
#the BEGNNING> If we reorient the edges like this, we can use the directional graph
#information to construct the super-contigs in a greedy way, by merging the individual
#contigs in a specific 'path' in the cluster from the directed graph.
#We need all the edges in the graph:
print "Flipping the edges in the graph:\n";
my @edges = $dot_graph->edges;

my $edge_flip_counter;
#Iterating through each edge:
foreach my $edge (@edges) {
	#In order to check if the edges are in the right orientation, we need to get the
	#label information for each one of them:
	my $label = $dot_graph->get_edge_attribute($edge->[0], $edge->[1], 'label');
	my @label = split(/,/,$label);
	#Each element from @label has a meaning:
	my $overlap_info = {
		overlap_type 		=> $label[0],
		overlap_length		=> $label[1],
		mismatches			=> $label[2],
		edits				=> $label[3],
		from_ctg_length		=> $label[4],
		ov_startcoord_from 	=> $label[5],
		ov_endcoord_from	=> $label[6],
		to_ctg_length		=> $label[7],
		ov_startcoord_to	=> $label[8],
		ov_endcoord_to		=> $label[9]
	};

	#We also need the node names:
	my $from_node = $edge->[0];
	my $to_node   = $edge->[1];

	#We can use the overlap beggining and ending coordinates to check if edge is in the
	#correct orientation (END -> BEG):
	if ($overlap_info->{'ov_startcoord_from'} == 0) {
		$edge_flip_counter++;
		#Deleting the wrong direction edge:
		$dot_graph->delete_edge($from_node, $to_node);

		#Adding the reversed edge
		$dot_graph->add_edge($to_node, $from_node);

		#We also have to change the order of the label data:
		my $new_overlap_info = $overlap_info;
		$new_overlap_info->{'from_ctg_length'} 		= $label[7];
		$new_overlap_info->{'ov_startcoord_from'}	= $label[8];
		$new_overlap_info->{'ov_endcoord_from'} 	= $label[9];
		$new_overlap_info->{'to_ctg_length'}		= $label[4];
		$new_overlap_info->{'ov_startcoord_to'}  	= $label[5];
		$new_overlap_info->{'ov_endcoord_to'} 		= $label[6];

		#Replacing the old label with the new one:
		$dot_graph->set_edge_attribute($to_node, $from_node, 'label', $new_overlap_info);
	} else {
		$dot_graph->set_edge_attribute($from_node, $to_node, 'label', $overlap_info);
	}
}
print "Number of edges flipped = $edge_flip_counter\n"; 
print "Done!\n\n";

######################################################
#### Identifying the overlapping contigs in graph ####
######################################################
#The graph file contains the overlap map for the different contig clusters. In order to
#merge the clusters into super-contigs, we have to extract all the paths corresponding
#to the longest overlap between the contigs in a cluster. In order to do this, we need to
#compute the graph traversal.

print "Finding all overlap paths in graph:\n";
die "Graph contains cycle!" if $dot_graph->has_a_cycle; #otherwise program will be stuck
my $paths = build_paths($dot_graph);
my $number_of_paths = @$paths;

#Counting how many vertices are contained in paths:
my %vertex_span;
foreach my $path (@$paths) {
	foreach my $vertex (@$path) {
		$vertex_span{$vertex}++;
	}
}
my $seen_vertex_count = keys %vertex_span;
my $vertex_repetition_count = sum(values %vertex_span);

print "Found $number_of_paths paths in graph\n"; 
print "Unique vertices present in all paths: $seen_vertex_count\n";
print "Total number of vertices in graph (including repeated): $vertex_repetition_count\n";  
print "Done!\n\n";

##################################################
#### Merging the overlapping contigs in graph ####
##################################################
#Creating merging statistics output file:
open (my $info_out, ">$info_file") || die "Can't open $info_file. $!\n";

#Adding header to information file w/ run informations:
my @file_stats = stat($info_out);
my $last_modify_time = scalar localtime $file_stats[9];
my $header =
"Merged contigs information file
File: $info_file;
Last modification time: $last_modify_time;
Input files:
 - All contigs FASTq file: $allcontigs_file;
 - Graph file: $graph_dot_file;
 - Cluster files: $cluster_files ($number_of_cluster_files);\n";
print $info_out "$header";

#Now that we have the paths, we can use the overlap information to extend the contigs in
#a path/cluster:
my %extended_contigs; #will hold the extended contig sequence and information
my $count = 0;
my %path_branches;

print "Merging contigs:\n"; 
#Loop to extend the contigs:
foreach my $overlap_path (@$paths) {
	$count++;
	my $name = "merged_contig_$count";
	my $extended_contig_seq = ''; #will hold the merged contig sequence
	my $total_error; #total number of "errors" in overlap (mismatches + edits)
	my $path_score; #total number of errors/total length of overlap path
	my @contig_names = @$overlap_path;	#list of contigs present in current path
	my $number_of_contigs = @contig_names; #number of contigs in path
	my $root_contig = $contig_names[0]; #first contig in the path
	my @sequences; #will hold all the sequences from the contigs with the
				   #overlapping regions deleted from the 'to' contig

	#Start printing to info output file:
	print $info_out "\nCLUSTER: $name\nparent_contigs\ttotal_length\tleft_ovlp_rmvd_length\n";

	#Loop through each contig in each path:
	foreach my $i (0..$#contig_names) {
		my $seq = $records{$contig_names[$i]}{'seq'};
		my $seq_length = length($seq);
		print $info_out "$contig_names[$i]\t$seq_length\t";
		
		#Removing the overlap region from all 'to' contigs:
		if ($dot_graph->has_edge($contig_names[$i-1], $contig_names[$i])) {
			my $overlap_info = $dot_graph->get_edge_attribute($contig_names[$i-1], $contig_names[$i], 'label');
			my $overlap_length = $overlap_info->{'overlap_length'};
			$seq = substr($seq, $overlap_length);
			push(@sequences, $seq);

			my $no_overlap_length = length($seq);
			print $info_out "$no_overlap_length\n";
			
			my $overlap_mismatches = $overlap_info->{'mismatches'};
			my $overlap_edits = $overlap_info->{'edits'};
			$total_error = $overlap_mismatches + $overlap_edits;
		} else {
			#Getting the contig sequence from %records:
			push(@sequences, $seq);
			print $info_out "NA\n";
		}
	}
	#Now we can concatenate each sequence string
	$extended_contig_seq = join('', @sequences);
	my $merged_contig_length = length($extended_contig_seq);
	
	#And calculate the super contig merging score:
	$path_score = $total_error/($merged_contig_length*$number_of_contigs);
	
	#Populating the %path_branches hash:
	push(@{$path_branches{$root_contig}->{'superctgs'}}, $name);
	push(@{$path_branches{$root_contig}->{'number_of_contigs'}}, $number_of_contigs);
	push(@{$path_branches{$root_contig}->{'total_error'}}, $total_error);
	push(@{$path_branches{$root_contig}->{'total_length'}}, $merged_contig_length);
	push(@{$path_branches{$root_contig}->{'score'}}, $path_score);
	
	#Printing more stuff to the information file:
	$extended_contigs{$name}{merged_contigs} = \@contig_names;
	$extended_contigs{$name}{seq} 			 =  $extended_contig_seq;
	print $info_out "merged_contig_length: $merged_contig_length\ntotal_error: $total_error\n";
}

close($info_out);

#Computing metrics of merged contigs:
my @merged_contigs_length = map {length($extended_contigs{$_}{seq})} keys %extended_contigs;
%metrics = sequence_metrics(@merged_contigs_length);
print_metrics(%metrics);
print "Done!\n\n"; 

#Print merged contig sequences to output file:
open(my $contigs_out, ">$output_file") || die "Can't open $output_file $!\n";
foreach my $contig_name (sort {substr($a, 14) <=> substr($b, 14)} keys %extended_contigs) {
	my $seq = $extended_contigs{$contig_name}{'seq'};
	print $contigs_out ">$contig_name\n$seq\n";
}
close($contigs_out);
####################################################################
#### Filtering path branches and selecting path with best score ####
####################################################################
#Now that we have a hash grouping the merged contigs by their root contig, we can select
#the paths that have the smallest score value. This way, we can reduce the number of 
#duplicated contigs that are increasing the overall size of our assembly:
print "Selecting best scoring merged contigs:\n";

open(my $info_out_selected, ">$info_file2") || die "Can't open $info_file2. $!\n"; 
#Adding header to information file w/ run informations:
@file_stats = stat($info_out_selected);
$last_modify_time = scalar localtime $file_stats[9];
$header =
"Selected merged contigs information file
File: $info_file2;
Last modification time: $last_modify_time;
Input files:
 - All contigs FASTq file: $allcontigs_file;
 - Graph file: $graph_dot_file;
 - Cluster files: $cluster_files ($number_of_cluster_files);
 - Merged contigs before selection = $count;
 //
 root\tpaths_from_root\tselected_merged_contig\t\ttotal_error\tlength\tnumber_of_contigs_in_path\tscore\tnumber_of_ties\ttiebreaker\n";
print $info_out_selected "$header";

my @selected_supercontigs;
foreach my $root (keys %path_branches) {
	my @scores = @{$path_branches{$root}->{'score'}};
	my $paths_from_root = @scores;
	#The "best" path is the one that has the smallest score:
	my $min_score = min(@scores);
	
	#Tiebreakers:
	#First, check if there is a tie:
	my @index_of_repeated_values = grep $scores[$_] == $min_score, 0..$#scores;
	my $winner_index; #index of winner merged contig after tiebreak
	my $winner_contig; #winner merged contig after tiebreak
	
	#If there is a tie:
	if (@index_of_repeated_values > 1) { 
		my $num_of_ties = @index_of_repeated_values;
		#Case 1: if score == 0, keep longest merged contig
		if ($min_score == 0) {
			my @merged_contigs_length = map {$path_branches{$root}->{'total_length'}->[$_]} @index_of_repeated_values;
			my $max_length = max(@merged_contigs_length);
			$winner_index = first_index {$_ eq $max_length} @scores; 
			$winner_contig = $path_branches{$root}->{'superctgs'}->[$winner_index];
			my $error = $path_branches{$root}->{'total_error'}->[$winner_index];
			my $number_of_contigs = $path_branches{$root}->{'number_of_contigs'}->[$winner_index];
			
			print $info_out_selected "$root\t$paths_from_root\t$winner_contig\t$error\t$max_length\t$number_of_contigs\t$min_score\t$num_of_ties\tlongest\n";
		} else {
			#Case 2: if two or more contigs have same score, keep the one with the lowest
			#number of errors:		
			my @total_errors = map{$path_branches{$root}->{'total_error'}->[$_]} @index_of_repeated_values;
			my $min_error = min(@total_errors);
			$winner_index = first_index {$_ eq $min_error} @scores;
			$winner_contig = $path_branches{$root}->{'superctgs'}->[$winner_index];
			my $length = $path_branches{$root}->{'total_length'}->[$winner_index];
			my $number_of_contigs = $path_branches{$root}->{'number_of_contigs'}->[$winner_index];
			
			print $info_out_selected "$root\t$paths_from_root\t$winner_contig\t$min_error\t$length\t$number_of_contigs\t$min_score\t$num_of_ties\tlowest error\n";
		}
	} 
	#If there is no tie:
	else {
		$winner_index = $#index_of_repeated_values; #the winner index is the only index in the index array
		$winner_contig = $path_branches{$root}->{'superctgs'}->[$winner_index];
		my $length = $path_branches{$root}->{'total_length'}->[$winner_index];
		my $number_of_contigs = $path_branches{$root}->{'number_of_contigs'}->[$winner_index];
		my $error = $path_branches{$root}->{'total_error'}->[$winner_index];
		
		print $info_out_selected "$root\t$paths_from_root\t$winner_contig\t$error\t$length\t$number_of_contigs\t$min_score\t0\tNA\n";
	}
	push(@selected_supercontigs, $winner_contig);
}

close($info_out_selected);

#Checking metrics after selection:
my @selected_contigs_length = map {length($extended_contigs{$_}{'seq'})} @selected_supercontigs;
%metrics = sequence_metrics(@selected_contigs_length);

print "Metrics after merged contig selection:\n"; 
print_metrics(%metrics);
 	
#Print selected merged contig sequences to output file:
open (my $selected_contigs_out, ">$output_file2") || die "Can't create $output_file2. $!\n";
foreach my $selected_contig_name (sort {substr($a, 14) <=> substr($b, 14)} @selected_supercontigs) {
	my $seq = $extended_contigs{$selected_contig_name}{'seq'};
	print $selected_contigs_out ">$selected_contig_name\n$seq\n"; 
}

close($selected_contigs_out);

#######################################################################
#### Printing final merged contigs + singleton clusters fasta file ####
#######################################################################
#Now that we have the selected merged contigs, we can output the final contigs (merged +
#single-contig clusters) to a file:

#First, get single contigs in graph:
my @all_contigs_in_graph = $dot_graph->vertices;
my @all_contigs = keys %records;
my @single_contigs = array_minus(@all_contigs, @all_contigs_in_graph);

#Getting metrics of final contig file:
my @single_contigs_length = map {length($records{$_}{'seq'})} @single_contigs;
my @all_merged_contigs_length = (@single_contigs_length, @selected_contigs_length);
%metrics = sequence_metrics(@all_merged_contigs_length);

print "Final sequence file metrics:\n"; 
print_metrics(%metrics);

#Printing final output:
open(my $all_contigs_out, ">$output_file4") || die "Can't open $output_file4. $!\n"; 
foreach my $contig_name (sort {$a <=> $b} @single_contigs) {
	my $seq = $records{$contig_name}{'seq'};
	print $all_contigs_out ">$contig_name\n$seq\n";
}

#Appending all selected contigs to final output file:
foreach my $selected_contig (sort {substr($a, 14) <=> substr($b, 14)} @selected_supercontigs) {
	my $seq = $extended_contigs{$selected_contig}{'seq'};
	print $all_contigs_out ">$selected_contig\n$seq\n"; 
}

close($all_contigs_out);



#####################
#### Subroutines ####
#####################

#Subroutine to find all paths starting from source nodes in the graph:
#(Written by ikegami, http://stackoverflow.com/a/41646812/2975263)
sub build_paths {
   my ($graph) = @_;

   my @paths;

   local *_helper = sub {
      my $v = $_[-1];
      my @successors = $graph->successors($v);
      if (@successors) {
         _helper(@_, $_)
            for @successors;
      } else {
         push @paths, [ @_ ];
      }
   };

   _helper($_)
      for $graph->source_vertices();

   return \@paths;
}

sub sequence_metrics {
	my (@contig_lengths) = @_;
	@contig_lengths = sort {$a <=> $b} @contig_lengths;
	
	#Calculating metrics:
	#total sum of contig lengths
	my $total_length = sum(@contig_lengths); 
	
	#Median length:
	my $median_length;
	my $array_size = @contig_lengths;
	if ($array_size % 2) { #array size is odd
		$median_length = $contig_lengths[$array_size/2];
	} else {
		$median_length = ($contig_lengths[($array_size/2)-1] + $contig_lengths[$array_size/2])/2;
	}
	
	#Average length:
	my $average_length = $total_length/$array_size;
	
	#N50:
	my $goal = $total_length/2;
	my $current_sum = 0;
	my $n50;
	do {
		$n50 = pop @contig_lengths;	
		$current_sum += $n50;
	} until ($current_sum >= $goal);
	
	#Storing the metrics in a hash:
	my %metrics = (
		number_of_entries 	=> $array_size,
		total_length 		=> $total_length,
		median_length 		=> $median_length,
		average_length		=> $average_length,
		N50					=> $n50
	);
	
	return(%metrics);
}
		
sub print_metrics {
	my (%metrics) = @_;
	
	print "Total number of contigs 	 = $metrics{'number_of_entries'}\n";
	print "Total length of contigs 	 = $metrics{'total_length'}\n";  
	print "Median length of contigs  = $metrics{'median_length'}\n";
	print "Average length of contigs = $metrics{'average_length'}\n";   
	print "N50 = $metrics{'N50'}\n\n";  
}