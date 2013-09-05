#!/usr/bin/env ruby

require 'genevalidator/clusterization'
require 'genevalidator/sequences'
require 'genevalidator/output'
require 'genevalidator/validation'
require 'genevalidator/exceptions'
require 'genevalidator/tabular_parser'
require 'bio-blastxmlparser'
require 'rinruby'
require 'net/http'
require 'open-uri'
require 'uri'
require 'io/console'
require 'yaml'

class Blast

  attr_reader :type
  attr_reader :fasta_filepath
  attr_reader :html_path
  attr_reader :yaml_path
  attr_reader :filename
  # current number of the querry processed
  attr_reader :idx
  attr_reader :start_idx
  #array of indexes for the start offsets of each query in the fasta file
  attr_reader :query_offset_lst

  attr_reader :vlist

  ##
  # Initilizes the object
  # Params:
  # +fasta_filepath+: query sequence fasta file with query sequences
  # +type+: query sequence type; can be :nucleotide or :protein
  # +xml_file+: name of the precalculated blast xml output (used in 'skip blast' case)
  # +vlist+: list of validations
  # +start_idx+: number of the sequence from the file to start with
  def initialize(fasta_filepath, type, vlist, xml_file = nil, start_idx = 1)
    begin

      puts "\nDepending on your input and your computational resources, this may take a while. Please wait...\n\n"

      if type == "protein"
        @type = :protein
      else 
        @type = :nucleotide
      end

      @fasta_filepath = fasta_filepath
      @xml_file = xml_file
      @vlist = vlist
      @idx = 0
      @start_idx = start_idx

      raise FileNotFoundException.new unless File.exists?(@fasta_filepath)
      fasta_content = IO.binread(@fasta_filepath);

      # type validation: the type of the sequence in the FASTA correspond to the one declared by the user
      if @type != type_of_sequences(fasta_content)
        raise SequenceTypeError.new
      end

      # create a list of index of the queries in the FASTA
      @query_offset_lst = fasta_content.enum_for(:scan, /(>[^>]+)/).map{ Regexp.last_match.begin(0)}
      @query_offset_lst.push(fasta_content.length)
      fasta_content = nil # free memory for variable fasta_content

      # redirect the cosole messages of R
      R.echo "enable = nil, stderr = nil, warn = nil"

      # build path of html folder output
      path = @fasta_filepath.scan(/(.*)\/[^\/]+$/)[0][0]
      if path == nil
        @html_path = "html"
      else
        @html_path ="#{path}/html"
      end
      @yaml_path = path

      @filename = @fasta_filepath.scan(/\/([^\/]+)$/)[0][0]

      # create 'html' directory
      FileUtils.rm_rf(@html_path)
      Dir.mkdir(@html_path)

      # copy auxiliar folders to the html folder
      FileUtils.cp_r("aux/css", @html_path)
      FileUtils.cp_r("aux/js", @html_path)
      FileUtils.cp_r("aux/img", @html_path)
      FileUtils.cp_r("aux/font", @html_path)

    rescue SequenceTypeError => error
      $stderr.print "Sequence Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file is not FASTA or the --type parameter is incorrect.\n"      
      exit
    rescue FileNotFoundException => error
      $stderr.print "File not found error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file does not exist.\n"
      exit 
    end
  end

  ##
  # Calls blast according to the type of the sequence
  def blast
    begin
      if @xml_file == nil
 
        #file seek for each query
        @query_offset_lst[0..@query_offset_lst.length-2].each_with_index do |pos, i|
      
          if (i+1) >= @start_idx
            query = IO.binread(@fasta_filepath, @query_offset_lst[i+1] - @query_offset_lst[i], @query_offset_lst[i]);

            #call blast with the default parameters
            if type == :protein
              output = call_blast_from_stdin("blastp", query, 11, 1)
            else
              output = call_blast_from_stdin("blastx", query, 11, 1)
            end

            #save output in a file
            xml_file = "#{@fasta_filepath}_#{i+1}.xml"
            File.open(xml_file , "w") do |f| f.write(output) end

            #parse output
            parse_xml_output(output)   
          else
            @idx = @idx + 1
          end
        end
      else
        file = File.open(@xml_file, "rb").read

        #check the format of the input file
        # check xml format
        begin
          parse_xml_output(file)      
        rescue Exception => error
          #tabular format
          iterator = TabularParser.new(file)
          while iterator.has_next
            iterator.next
          end
        end
      end

    rescue SystemCallError => error
      $stderr.print "Load error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file is not valid\n"      
      exit
    end
  end

  ##
  # Calls blast from standard input with specific parameters
  # Params:
  # +command+: blast command in String format (e.g 'blastx' or 'blastp')
  # +query+: String containing the the query in fasta format
  # +gapopen+: gapopen blast parameter
  # +gapextend+: gapextend blast parameter
  # Output:
  # String with the blast xml output
  def call_blast_from_stdin(command, query, gapopen, gapextend, db="nr -remote")
    begin
      raise TypeError unless command.is_a? String and query.is_a? String

      evalue = "1e-5"

      #output format = 5 (XML Blast output)
      blast_cmd = "#{command} -db #{db} -evalue #{evalue} -outfmt 5 -gapopen #{gapopen} -gapextend #{gapextend}"
      cmd = "echo \"#{query}\" | #{blast_cmd}"
      #puts "Executing \"#{blast_cmd}\"... This may take a while..."
      output = %x[#{cmd} 2>/dev/null]

      if output == ""
        raise ClasspathError.new
      end

      return output

    rescue TypeError => error
      $stderr.print "Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: one of the arguments of 'call_blast_from_file' method has not the proper type\n"
      exit
    rescue ClasspathError => error
      $stderr.print "BLAST error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: Did you add BLAST path to CLASSPATH?\n" 
      exit 
    end
  end

  ##
  # Calls blast from file with specific parameters
  # Param:
  # +command+: blast command in String format (e.g 'blastx' or 'blastp')
  # +filename+: name of the FAST file
  # +query+: +String+ containing the the query in fasta format
  # +gapopen+: gapopen blast parameter
  # +gapextend+: gapextend blast parameter
  # Output:
  # String with the blast xml output
  def call_blast_from_file(command, filename, gapopen, gapextend, db="nr -remote")
    begin  
      raise TypeError unless command.is_a? String and filename.is_a? String

      evalue = "1e-5"

      #output = 5 (XML Blast output)
      cmd = "#{command} -query #{filename} -db #{db} -evalue #{evalue} -outfmt 5 -gapopen #{gapopen} -gapextend #{gapextend} "
      puts "Executing \"#{cmd}\"..."
      puts "This may take a while..."
      output = %x[#{cmd}          if xml_file == nil
            file = File.open(xml_file, "rb").read
            b.parse_xml_output(file)
          end 2>/dev/null]

      if output == ""
        raise ClasspathError.new      
      end

      return output

    rescue TypeError => error
      $stderr.print "Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: one of the arguments of 'call_blast_from_file' method has not the proper type\n"      
      exit
    rescue ClasspathError =>error
      $stderr.print "BLAST error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Did you add BLAST path to CLASSPATH?\n"      
      exit
    end
  end

  ##
  # Parses the xml blast output 
  # Param:
  # +output+: +String+ with the blast output in xml format
  def parse_xml_output(output)

    iterator = Bio::BlastXMLParser::NokogiriBlastXml.new(output).to_enum

    begin
      @idx = @idx + 1      
      if @idx < @start_idx  
        iter = iterator.next 
      else     
        sequences = parse_next_query(iterator) #returns [hits, predicted_seq]
        if sequences == nil          
          @idx = @idx -1
          break
        end

        hits = sequences[0]
        prediction = sequences[1]
        # get the @idx-th sequence  from the fasta file
        i = @idx-1
       
        ### add exception
        query = IO.binread(@fasta_filepath, @query_offset_lst[i+1] - @query_offset_lst[i], @query_offset_lst[i])
        prediction.raw_sequence = query.scan(/[^\n]*\n([A-Za-z\n]*)/)[0][0].gsub("\n","")              
        #file seek for each query
        
        # do validations
        v = Validation.new(prediction, hits, vlist, @type, @filename, @html_path, @yaml_path, @idx, @start_idx)
        query_output = v.validate_all
        query_output.generate_html

        query_output.print_output_console
        query_output.print_output_file_yaml

      end
=begin
      rescue NoMethodError => error
        puts error.backtrace
        $stderr.print "NoMethod error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: input file is not in blast xml format.\n"        
        exit
=end
      rescue StopIteration
        return
    end while 1

  end

  ##
  # Parses the next query from the blast xml output query
  # Params:
  # +iterator+: blast xml iterator for hits
  # Outputs:
  # output1: an array of +Sequence+ ojbects for hits
  # output2: +Sequence+ object for the predicted sequence
  def parse_next_query(iterator)
    begin
      raise TypeError unless iterator.is_a? Enumerator

      hits = Array.new
      predicted_seq = Sequence.new
      iter = iterator.next

      #puts "#################################################"
      #puts "Parsing query #{iter.field('Iteration_iter-num')}"

      # get info about the query
      predicted_seq.xml_length = iter.field("Iteration_query-len").to_i
      if @type == :nucleotide
        predicted_seq.xml_length /= 3
      end
      predicted_seq.definition = iter.field("Iteration_query-def")

      # parse blast the xml output and get the hits
      iter.each do | hit | 
        
        seq = Sequence.new

        seq.xml_length = hit.len.to_i        
        seq.seq_type = @type
        seq.id = hit.hit_id
        seq.definition = hit.hit_def
        seq.accession_no = hit.accession

        # get all high-scoring segment pairs (hsp)
        hsps = []
        hit.hsps.each do |hsp|
          current_hsp = Hsp.new
          current_hsp.hsp_evalue = hsp.evalue.to_i
          
          current_hsp.hit_from = hsp.hit_from.to_i
          current_hsp.hit_to = hsp.hit_to.to_i
          current_hsp.match_query_from = hsp.query_from.to_i
          current_hsp.match_query_to = hsp.query_to.to_i

          if @type == :nucleotide
            current_hsp.match_query_from /= 3 
            current_hsp.match_query_to /= 3             
          end


          current_hsp.query_reading_frame = hsp.query_frame.to_i

          current_hsp.hit_alignment = hsp.hseq.to_s
          current_hsp.query_alignment = hsp.qseq.to_s
          current_hsp.align_len = hsp.align_len.to_i

          hsps.push(current_hsp)
        end

        seq.hsp_list = hsps
        hits.push(seq)
      end     
    
      return [hits, predicted_seq]

    rescue TypeError => error
      $stderr.print "Type error at #{error.backtrace[0].scan(/\/([^\/]+:\d+):.*/)[0][0]}. Possible cause: you didn't call parse method first!\n"       
      exit
    rescue StopIteration
      nil
    end
  end

  ##
  # Method copied from sequenceserver/sequencehelpers.rb
  # Params:
  # sequence_string: String of which we mfind the composition
  # Output:
  # a Hash
  def composition(sequence_string)
    count = Hash.new(0)
    sequence_string.scan(/./) do |x|
      count[x] += 1
    end
    count
  end

  ##
  # Method copied from sequenceserver/sequencehelpers.rb
  # Strips all non-letter characters. guestimates sequence based on that.
  # If less than 10 useable characters... returns nil
  # If more than 90% ACGTU returns :nucleotide. else returns :protein
  # Params:
  # +sequence_string+: String to validate
  # Output:
  # nil, :nucleotide or :protein
  def guess_sequence_type(sequence_string)
    cleaned_sequence = sequence_string.gsub(/[^A-Z]/i, '') # removing non-letter characters
    cleaned_sequence.gsub!(/[NX]/i, '') # removing ambiguous characters

    return nil if cleaned_sequence.length < 10 # conservative

    composition = composition(cleaned_sequence)
    composition_NAs = composition.select { |character, count|character.match(/[ACGTU]/i) } # only putative NAs
    putative_NA_counts = composition_NAs.collect { |key_value_array| key_value_array[1] } # only count, not char
    putative_NA_sum = putative_NA_counts.inject { |sum, n| sum + n } # count of all putative NA
    putative_NA_sum = 0 if putative_NA_sum.nil?

    if putative_NA_sum > (0.9 * cleaned_sequence.length)
      return :nucleotide
    else
      return :protein
    end
  end

  ##
  # Method copied from sequenceserver/sequencehelpers.rb
  # Splits input at putative fasta definition lines (like ">adsfadsf"), guesses sequence type for each sequence.
  # If not enough sequence to determine, returns nil.
  # If 2 kinds of sequence mixed together, raises ArgumentError
  # Otherwise, returns :nucleotide or :protein
  # Params:
  # +sequence_string+: String to validate
  # Output:
  # nil, :nucleotide or :protein
  def type_of_sequences(fasta_format_string)
    # the first sequence does not need to have a fasta definition line
    sequences = fasta_format_string.split(/^>.*$/).delete_if { |seq| seq.empty? }

    # get all sequence types
    sequence_types = sequences.collect { |seq| guess_sequence_type(seq) }.uniq.compact

    return nil if sequence_types.empty?

    if sequence_types.length == 1
      return sequence_types.first # there is only one (but yes its an array)
    else
      raise ArgumentError, "Insufficient info to determine sequence type. Cleaned queries are: #{ sequences.to_s }"
    end
  end

end


