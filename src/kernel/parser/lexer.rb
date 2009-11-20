# File.expand_path...
# require 'sexp'
# require 'ruby_parser_extras'

module MagRp

class RubyLexer
  # attr's in first opening in rp_classes.rb

  def initialize
    @cond = StackState.new()
    @cmdarg = StackState.new()
    @nest = 0
    @line_num = 1
    @last_else_src_offset = -1
    # @comments  not used, this parser not for use to implement RDoc
    @mydebug = MagRp::debug > 1
    reset
    # @keyword_table installed by _install_wordlist from RubyParser
  end

  def _install_wordlist(hash)
    # called from RubyParser#initialize
    @keyword_table = hash
  end

  def reset
    @command_start = true
    @lex_strterm = nil
    @yacc_value = nil

    @src_scanner = nil
    @lex_state = nil
  end

  def install_source( src)
    unless src._isString
      raise "bad src: #{src.inspect}" 
    end
    sc = RpStringScanner.new(src)
    @src_scanner = sc
    @src_regions = [ ]  # stack for handling heredoc
    ev = @parser.env
    ev.scanner=( sc )
    ev.reset
  end

  def line_for_offset(byte_ofs)
    # for debugging
    # returns line number or -1 if not determinable
    @src_scanner.line_for_offset(byte_ofs)
  end

  def src_line_for_offset(byte_ofs)
    # for debugging , returns a String containing a line of the source
    @src_scanner.src_line_for_offset(byte_ofs)
  end

  def near_eos?(margin)
    # used by syntax error hints
    @src_scanner.near_eos?(margin)
  end

  def self.state_to_s(v)
    # used in debugging only
    if v == Expr_beg 
      'Expr_beg'
    elsif v == Expr_end
      'Expr_end'
    elsif v == Expr_arg
      'Expr_arg'
    elsif v == Expr_cmdArg
      'Expr_cmdArg'
    elsif v == Expr_endArg
      'Expr_endArg'
    elsif v == Expr_mid
      'Expr_mid'
    elsif v == Expr_fname
      'Expr_fname'
    elsif v == Expr_dot
      'Expr_dot'
    elsif v == Expr_class
      'Expr_class'
    else
      raise 'invalid lexer state'
      nil
    end
  end

  # def is_argument ; end ;  # deleted

  def arg_ambiguous
    self.warning("Ambiguous first argument to method call, near line #{@line_num}")
  end

  def expr_beg_push( val )
    @cond.push( false )
    @cmdarg.push( false ) 
    @lex_state = Expr_beg
    @yacc_value = val
  end

  def fix_arg_lex_state
    ls = @lex_state
    if (ls & Expr_IS_fname_dot)._not_equal?(0)
      @lex_state = Expr_arg
    else
      @lex_state = Expr_beg
    end
  end

  def heredoc( *args)  # [
    # unused_sym, func, doc_id, end_of_doc_re = args
    func = args[1]
    # eos = args[2] #  doc_id
    eos_re = args[3]

    # indent  = (func & STR_FUNC_INDENT)._not_equal?( 0)
    expand  = (func & STR_FUNC_EXPAND)._not_equal?( 0)

    src = @src_scanner
    if @mydebug
      puts "  entering heredoc(): at byte #{src.pos} line #{@line_num} "
      puts "         args  #{args.inspect} "
      puts "         eos_re #{eos_re.inspect} "
    end

    # src is positioned at start of a data line of the doc
    #  or at start of the heredoc ending identifier

    if src.check_advance(eos_re)
      # eos_re includes terminating \n ,
      @yacc_value = args[2] #  eos
      #
      rest_of_src_ofs = src.pos 
      rest_of_src_limit = src.limit
      rest_of_src_line = @line_num
      regions = @src_regions
      rofs = regions.size - 1
      if rofs < 0
        raise_error('src_regions underflow at end of heredoc')
      end
      # top of regions stack is remainder of the line containing heredoc start ident
      # resume lexing that region
      # and save remainder of source (after end of heredoc) as top of stack
      topr = regions[rofs] 
      @line_num = topr.line_num
      src.set_pos_limit( topr.offset , topr.limit ) 
      regions[rofs] = SrcRegion.new( rest_of_src_line, rest_of_src_ofs, rest_of_src_limit)
      if @mydebug
        puts "  found end of heredoc at byte #{src.pos}"
      end
      return :tSTRING_END
    end
    found_eos = false

    cstring_buffer = []
    @string_buffer = cstring_buffer

    if expand then
      if (s_matched = src.scan(/#[$@]/)) then
        src.advance( -1 ) # FIX omg stupid
        @yacc_value = s_matched
        return :tSTRING_DVAR
      elsif (s_matched = src.scan(/#[{]/)) then
        @yacc_value = s_matched
        return :tSTRING_DBEG
      elsif src.check_advance(/#/) then
        cstring_buffer << '#'
      end

      until found_eos do
        t_a_s_args = [ func, "\n", /\n/ , nil, nil ]
        cres = tokadd_string( *t_a_s_args )

        if cres.equal?( :tEOF )
          err_msg = "can't match #{eos_re.inspect} anywhere in "
          rb_compile_error( err_msg)
        end

        if cres == "\n" then
          cstring_buffer << cres
          src.advance(1) # past \n
          @line_num = @line_num + 1
        else
          @yacc_value = cstring_buffer._join.delete("\r")
          return :tSTRING_CONTENT
        end
	if src.eos? 
	  err_msg = "can't match #{eos_re.inspect} anywhere in "
	  rb_compile_error( err_msg) 
	end
        found_eos = src.check(eos_re)
      end
    else
      until found_eos do
        cstring_buffer << src.scan(/.*(\n|\z)/)
        if src.eos?
          err_msg = "can't match #{eos_re.inspect} anywhere in "
          rb_compile_error( err_msg)
        end
        @line_num = @line_num + 1
        found_eos = src.check(eos_re)
      end
    end
    # at this point, src is positioned at start of heredoc end 
    #  identifier

    # no change to  @lex_strterm 
    @yacc_value = cstring_buffer._join.delete("\r")
    return :tSTRING_CONTENT
  end # ]

  def heredoc_identifier( src )       # [
    # caller has just gotten success from src.check_advance(/\<\</) 
    term = nil
    term_pos = src.pos
    func = STR_FUNC_BORING
    cstring_buffer = []
    @string_buffer = cstring_buffer
    if @mydebug
      puts "  entering heredoc_identifier() at byte #{src.pos} "
    end

    indent = false
    if src.check_advance(/(-?)(['"`])(.*?)\2/) then
      term = src[2]
      term_pos = src.pos + 2
      unless src[1].empty? then
        func |= STR_FUNC_INDENT
        indent = true
      end
      func |= if term == "\'" then
                STR_SQUOTE
              elsif term == '"' then
                STR_DQUOTE
              else
                STR_XQUOTE
              end
      cstring_buffer << src[3]
    elsif src.check_advance(/-?(['"`])(?!\1*\Z)/) then
      rb_compile_error "unterminated here document identifier"
    elsif src.check_advance(/(-?)(\w+)/) then
      term = '"'
      term_pos = src.pos
      func |= STR_DQUOTE
      unless src[1].empty? then
        func |= STR_FUNC_INDENT
        indent = true
      end
      cstring_buffer << src[2]
    else
      return nil   # the '<<' just seen is a normal '<<' token
    end

    remainder_of_line_ofs = src.pos
    remainder_of_line_lnum = @line_num 
    if src.check_advance(/.*\n/) then
      # src is now at start of first data line of the heredoc
      # push a SrcRegion for remainder of line containing the heredoc start ident
      remainder_of_line_limit = src.pos
      @line_num = @line_num + 1
      rem_region = SrcRegion.new( remainder_of_line_lnum, remainder_of_line_ofs,
				 remainder_of_line_limit);
      csrc_regions = @src_regions  
      rofs = csrc_regions.size - 1
      if (rofs >= 0)   # handling a nested heredoc
        # set lexer to resume lexing for heredoc contents
        topr = csrc_regions[rofs] 
        @line_num = topr.line_num
        src.set_pos_limit( topr.offset , topr.limit ) 
        csrc_regions[rofs] = rem_region
      else
        csrc_regions << rem_region
      end
    else
      rb_compile_error( "unterminated here document identifier")
    end

    eos = cstring_buffer._join   # the doc_identifier
    eos_re  = indent ? /[ \t]*#{eos}(\r?\n|\z)/ : /#{eos}(\r?\n|\z)/
    @lex_strterm = [:heredoc, func, eos, eos_re ]

    if term == '`' then
      @yacc_value = RpNameToken.new( :"`" , term_pos )
      return :tXSTRING_BEG
    else
      @yacc_value = "\""
      return :tSTRING_BEG
    end
  end # ]

  def int_base10( s_matched , sign )
    @yacc_value = s_matched.to_i(10) * sign
    return :tINTEGER
  end

  def int_with_base(base, s_matched, sign)
    if s_matched[0].equal?( ?_ ) && s_matched[1].equal?( ?_ )  # s_matched =~ /__/
      rb_compile_error "Invalid numeric format"
    end
    str = s_matched[ 2, s_matched.size - 2 ]  # skip leading 0x 0b 0d etc
    v = str.to_i(base) * sign
    @yacc_value = v
    return :tINTEGER
  end

  def float_lit( s_matched , sign)
    if s_matched[0].equal?( ?_ ) && s_matched[1].equal?( ?_ )  # s_matched =~ /__/
      rb_compile_error "Invalid numeric format"
    end
    @yacc_value = s_matched.to_f * sign
    :tFLOAT
  end

  def lex_state=( v)
    # TODO remove consistency checks
    if v._isFixnum && v >= 0 && v <= Expr_class
      @lex_state = v
    else
      raise "lex_state= , invalid arg"
    end
  end

  ##
  #  Parse a number from the input stream.
  #
  # @param c The first character of the number.
  # @return A int constant wich represents a token.

  def parse_number # [
    @lex_state = Expr_end
    src = @src_scanner

    ch = src.peek_ch   # leading /[+-]?/  processing
    sign = 1
    if ch.equal?( ?- )
      sign = -1
      ch = src.advance_peek(1)
    elsif ch.equal?( ?+ )
      ch = src.advance_peek(1)
    end   

    if ch.equal?( ?0 ) 
      next_ch = src.peek_ahead(1)
      if src.ch_is_alpha( next_ch) 
        if src.check_advance(/0[xbd]\b/) then
          rb_compile_error "Invalid numeric format"
        elsif (s_matched = src.scan(/0x[a-f0-9_]+/i)) then
          int_with_base(16, s_matched, sign)
        elsif (s_matched = src.scan(/0b[01_]+/)) then
          int_with_base(2, s_matched, sign)
        elsif (s_matched = src.scan(/0d[0-9_]+/)) then
          int_with_base(10, s_matched, sign)
        elsif src.check_advance(/0(o|O)?[0-7_]*[89]/) then
          rb_compile_error "Illegal octal digit."
        elsif (s_matched = src.scan(/0(o|O)[0-7_]+/))
          int_with_base(8, s_matched, sign)
        elsif src.check_advance(/0(o|O)/) then
          int_with_base(8, "0o0", sign)
        elsif (s_matched = src.scan(/[\d_]+\.[\d_]+(e[+-]?[\d_]+)?\b|[+-]?[\d_]+e[+-]?[\d_]+\b/i)) then
          float_lit(s_matched, sign )
        else
          rb_compile_error "Bad number format"
        end
      elsif next_ch._not_equal?( ?. ) && (s_matched = src.scan(/0\b/)) then
        int_base10(s_matched, sign)   # common case of integer literal zero
      elsif (s_matched = src.scan(/0[0-7_]+/)) then
        int_with_base(8, "0o" << s_matched, sign)
      elsif src.check_advance(/[\d_]+_(e|\.)/) then
        rb_compile_error "Trailing '_' in number."
      elsif (s_matched = src.scan(/[\d_]+\.[\d_]+(e[+-]?[\d_]+)?\b|[+-]?[\d_]+e[+-]?[\d_]+\b/i)) then
        float_lit(s_matched, sign )
      elsif (s_matched = src.scan(/0\b/)) then
        int_base10(s_matched, sign)
      else
        rb_compile_error "Bad number format"
      end
    else
      if src.check_advance(/[\d_]+_(e|\.)/) then
        rb_compile_error "Trailing '_' in number."
      elsif (s_matched = src.scan(/[\d_]+\.[\d_]+(e[+-]?[\d_]+)?\b|[+-]?[\d_]+e[+-]?[\d_]+\b/i)) then
        float_lit(s_matched, sign )
      elsif (s_matched = src.scan(/[\d_]+\b/)) then
        int_base10(s_matched, sign)
      else
        rb_compile_error "Bad number format"
      end
    end
  end # ]

  def parse_quote 		#  [
    # beg, nnd, short_hand, c = nil, nil, false, nil  # all set below

    src = @src_scanner
    if (s_matched = src.scan(/[a-z0-9]{1,2}/i)) then # Long-hand (e.g. %Q{}).
      if  s_matched.size.equal?(2)
        rb_compile_error "unknown type of %string" 
      end
      # c, beg, short_hand = src.matched, src.getch, false
      c = s_matched
      beg_ch = src.getch
      short_hand = false
    else                               # Short-hand (e.g. %{, %., %!, etc)
      # c, beg, short_hand = 'Q', src.getch, true
      c = 'Q'
      beg_ch = src.getch 
      short_hand = true
    end

                 # exclude impossible or redundant terms
    if src.eos?  #  or c.equal?( RubyLexer::EOF) or beg.equal?(nil)
      rb_compile_error "unterminated quoted string meets end of file"
    end

    # Figure nnd-char.  "\0" is special to indicate beg=nnd and that no nesting?
    # nnd = { "(" => ")", "[" => "]", "{" => "}", "<" => ">"  }[beg]
    # nnd, beg = beg, "\0" if nnd.nil?
    if beg_ch.equal?( ?( )
       nnd = ")"
       nnd_re = /\)/
    elsif beg_ch.equal?( ?[ ) # ] 
       nnd = "]"
       nnd_re = /\]/
    elsif beg_ch.equal?( ?{ )
       nnd = "}"
       nnd_re = /\}/
    elsif beg_ch.equal?( ?< ) 
       nnd = ">"
       nnd_re = />/
    else
      nnd = ' '
      nnd[0] = beg_ch
      nnd_re = nil # on demand
      beg_ch = 0
      beg_re = /\000/
    end
    beg = ' '
    beg[0] = beg_ch

    # token_type, @yacc_value = nil, "%#{c}#{beg}"
    token_type = nil
    y_value = "%#{c}#{beg}"

    c_ch = c[0]
    if c_ch.equal?( ?Q ) # when 'Q' then
      ch = short_hand ? nnd : c + beg
      y_value = "%#{ch}"
      token_type = :tSTRING_BEG
      string_type =  STR_DQUOTE
    elsif c_ch.equal?( ?q ) # when 'q' then
      token_type = :tSTRING_BEG
      string_type = STR_SQUOTE
    elsif c_ch.equal?( ?W ) # when 'W' then
      src.check_advance(/\s*/)
      token_type = :tWORDS_BEG
      string_type =     STR_DQUOTE | STR_FUNC_AWORDS
    elsif c_ch.equal?( ?w ) # when 'w' then
      src.check_advance(/\s*/)
      token_type = :tAWORDS_BEG
      string_type =   STR_SQUOTE | STR_FUNC_AWORDS
    elsif c_ch.equal?( ?x ) #  when 'x' then
      token_type = :tXSTRING_BEG
      string_type =   STR_XQUOTE
      y_value = RpNameToken.new( y_value , src.pos )
    elsif c_ch.equal?( ?r ) #   when 'r' then
      token_type = :tREGEXP_BEG
      string_type =   STR_REGEXP
    elsif c_ch.equal?( ?s ) # when 's' then
      @lex_state  = Expr_fname
      token_type = :tSYMBEG
      string_type =  STR_SSYM
    end

    @yacc_value = y_value

    if token_type.equal?(nil)
      rb_compile_error "Bad %string type. Expected [Qqwxr\W], found '#{c}'." 
    end

    @lex_strterm = [:strterm, string_type, nnd, nnd_re , beg , beg_re ] 
    return token_type
  end # ]

  def parse_string(*strterm_descr)  # [
    # strterm_descr is  [ op_sym, func, term, term_re , beg , beg_re ]
    #  func is  logically 'string_type'
    #  op_sym  should be :strterm 
    #  term_re, beg_re maybe nil
 
    func = strterm_descr[1]
    if func.equal?(nil)			
      return :tSTRING_END
    end
    term = strterm_descr[2]
    term_re = strterm_descr[3]  # maybe nil
    if term_re.equal?(nil)
      term_re = Regexp.new( Regexp.escape( term ))
    end
    src = @src_scanner

    space = false
    awords = (func & STR_FUNC_AWORDS)._not_equal?( 0 )
    if @mydebug
      puts strterm_descr.inspect
      puts "   lexer: parse_string at byte #{src.pos} line #{@line_num} nest=#{@nest} awords=#{awords}"
    end

    if awords and src.check_advance(/\s+/)
      space = true 
    end
    # TODO  count embedded  LF  within string constants 
    if @nest == 0 && src.check_advance( term_re ) then
      if awords then
        strterm_descr[1] = nil   # we see func==nil next time and produce STRING_END
        return :tSPACE
      elsif (func & STR_FUNC_REGEXP)._not_equal?( 0 ) then
        @yacc_value = self.regx_options
        return :tREGEXP_END
      else
        @yacc_value = term
        return :tSTRING_END
      end
    end

    if space then
      return :tSPACE
    end

    cstring_buffer = []
    @string_buffer = cstring_buffer

    if (func & STR_FUNC_EXPAND)._not_equal?( 0 )
      if src.peek_ch.equal?( ?# ) 
        if src.check_advance(/#(?=[$@])/) then
          return :tSTRING_DVAR
        elsif src.check_advance(/#[{]/) then
          return :tSTRING_DBEG
        else # src.check_advance(/#/) 
          src.advance(1)
          cstring_buffer << '#'
        end
      end
    end

    # args are func, term, term_re, paren, paren_re 
    open = strterm_descr[4]
    open_re = strterm_descr[5] # maybe nil
    if  open_re.equal?(nil)
      if open._not_equal?(nil)
        open_re = Regexp.new( Regexp.escape( open ))
      end
    end
    t_a_s_args = [ func, term, term_re, open, open_re ]
    if tokadd_string(*t_a_s_args).equal?( :tEOF) then
      rb_compile_error "unterminated string meets end of file"
    end

    @yacc_value = cstring_buffer._join
    return :tSTRING_CONTENT
  end # ]

  def rb_compile_error msg
    msg += ". near line #{@line_num}: #{@src_scanner.rest[/^.*/].inspect}"
    raise SyntaxError, msg
  end

  def read_escape      # [
    # returns a String of length 1
    src = @src_scanner
    s_ch = src.peek_ch
    if s_ch.equal?( ?n )  # src.scan(/n/) # newline
      res = "\n"
      src.advance(1)
    elsif s_ch.equal?( ?\\ ) # src.scan(/\\/) # Backslash
      res = '\\'
      src.advance(1)
    elsif s_ch.equal?( ?t )  # src.scan(/t/) # horizontal tab
      res = "\t"
      src.advance(1)
    elsif s_ch.equal?( ?r ) # src.scan(/r/) # carriage-return
      res = "\r"
      src.advance(1)
    elsif s_ch.equal?( ?f ) # src.scan(/f/) # form-feed
      res = "\f"
      src.advance(1)
    elsif s_ch.equal?( ?v ) # src.scan(/v/) # vertical tab
      res = "\13"
      src.advance(1)
    elsif s_ch.equal?( ?a ) # src.scan(/a/) # alarm(bell)
      res = "\007"
      src.advance(1)
    elsif s_ch.equal?( ?e ) # src.scan(/e/) # escape
      res = "\033"
      src.advance(1)
    elsif s_ch.equal?( ?b ) # src.scan(/b/) # backspace
      res = "\010"
      src.advance(1)
    elsif s_ch.equal?( ?s ) # src.scan(/s/) # space
      res = " "
      src.advance(1)
    elsif (s_matched = src.scan(/[0-7]{1,3}/)) # octal constant
      res = s_matched.to_i(8).chr
    elsif src.check_advance(/x([0-9a-fA-F]{1,2})/) # hex constant
      res = src[1].to_i(16).chr
    elsif src.check_advance(/M-\\/) 
      cstr = self.read_escape
      cstr[0] = (cstr[0] | 0x80).chr   # c[0].ord
      res = cstr 
    elsif src.check_advance(/M-(.)/) then
      cstr = src[1]
      cstr[0] = (cstr[0] | 0x80).chr   # c[0].ord
      res = cstr
    elsif src.check_advance(/C-\\|c\\/) then
      cstr = self.read_escape
      cstr[0] = (cstr[0] & 0x9f).chr   # c[0].ord
      res = cstr
    elsif src.check_advance(/C-\?|c\?/) then
      res = 0177.chr
    elsif src.check_advance(/(C-|c)(.)/) then
      cstr = src[2]
      cstr[0] = (cstr[0] & 0x9f).chr   # c[0].ord
      res = cstr
    elsif src.check_advance(/[McCx0-9]/) || src.eos? then
      rb_compile_error("Invalid escape character syntax")
      res = nil
    else
      res = ' ' 
      res[0] = s_ch   # getch
      src.advance(1)
    end
    res
  end # ]

  def regx_options 
    src = @src_scanner
    if (s_matched = src.scan(/[a-z]+/)) then
      part_arr = s_matched.split(//).partition { |s| s =~ /^[ixmonesu]$/ }
      good = part_arr[0]
      bad = part_arr[1]
      if bad.size._not_equal?( 0)  then
        rb_compile_error("unknown regexp option%s - %s" %
                         [(bad.size > 1 ? "s" : ""), bad._join.inspect])
      end
      return good._join
    else
      return []
    end
  end

  def tokadd_escape(src , term) # [
    if src.check_advance(/\\\n/) then
      # just ignore
    elsif (s_matched = src.scan(/\\([0-7]{1,3}|x[0-9a-fA-F]{1,2})/)) then
      @string_buffer << s_matched
    elsif (s_matched = src.scan(/\\([MC]-|c)(?=\\)/)) then
      @string_buffer << s_matched
      self.tokadd_escape( src, term )
    elsif (s_matched = src.scan(/\\([MC]-|c)(.)/)) then
      @string_buffer << s_matched
    elsif src.scan(/\\[McCx]/) then
      rb_compile_error "Invalid escape character syntax"
    elsif (s_matched = src.scan(/\\(.)/m)) then
      @string_buffer << s_matched
    else
      rb_compile_error "Invalid escape character syntax"
    end
    if @mydebug
      puts "   end of tokadd_escape, string_buffer = #{@string_buffer.inspect}"
    end
  end # ]

  def tokadd_string(*args) # [
    # args are  func, term, term_re, paren, paren_re 
    func = args[0]
    awords = (func & STR_FUNC_AWORDS)._not_equal?( 0)
    expand = (func & STR_FUNC_EXPAND)._not_equal?( 0)
    if (func & STR_FUNC_REGEXP)._not_equal?( 0)
      regexp = true
      term = args[1]
    end

    paren_re = args[4] # nil if paren also nil
    term_re  = args[2] # nil if term also nil 
    src = @src_scanner

    if @mydebug 
      puts "   lexer: tokadd_string at byte #{src.pos} line #{@line_num}"
      puts "                     args  #{args.inspect} awords=#{awords}"
    end
    num_eols = 0
    until src.eos? do # [
      cres = nil
      s_ch = src.peek_ch 
      cnest = @nest
      if cnest.equal?( 0) && (s_matched = src.scan(term_re)) 
        src.advance( -1)
        break
      elsif paren_re && (s_matched = src.scan(paren_re)) 
        @nest = cnest + 1
      elsif cnest._not_equal?( 0) && (s_matched = src.scan(term_re)) then
        @nest = cnest - 1
      elsif awords && (s_matched = src.scan(/\s/)) 
        src.advance( -1)
        break
      elsif expand && (s_matched = src.scan(/#(?=[\$\@\{])/)) 
	src.advance( -1)
	break
      elsif expand && (s_matched = src.scan(/#(?!\n)/)) 
	# do nothing
      elsif s_ch.equal?( ?\\ ) # when src.check(/\\/) 
        next_ch = src.peek_ahead(1)
        if awords && next_ch.equal?( ?\n ) # src.scan(/\\\n/) 
          s_matched = "\\n" 
          src.advance(2)
          @string_buffer << "\n"
          next
        elsif awords && next_ch.equal?( ?\  ) # src.scan(/\\\s/)
          s_matched = "\\s" 
          src.advance(2)
          cres = ' '
        elsif expand && next_ch.equal?( ?\n ) # src.scan(/\\\n/) 
          s_matched = "\\n" 
          src.advance(2)
          next
        elsif regexp  #  regex && src.check(/\\/) 
          self.tokadd_escape( src, term )
          next
        elsif expand # expand && src.scan(/\\/) 
          s_matched = "\\"
          src.advance(1)
          cres = self.read_escape
          symbol = (func & STR_FUNC_SYMBOL)._not_equal?( 0)
          if symbol && cres._contains_string( '\\0') # symbol && cres =~ /\0/
            # This error path not in ruby_parser2.0.2
            rb_compile_error "symbol cannot contain '\\0'" 
          end
        elsif next_ch.equal?( ?\n ) #   src.scan(/\\\n/) then
          s_matched = "\\n"
          src.advance(2)
          # do nothing
        elsif next_ch.equal?( ?\\ ) # src.scan(/\\\\/) 
          s_matched = "\\\\"
          src.advance(2)
          escape = (func & STR_FUNC_ESCAPE)._not_equal?( 0)
          if escape
            @string_buffer << '\\' 
          end
          cres = '\\'
        else #  must be TRUE: src.scan(/\\/) 
          s_matched = "\\"
          src.advance(1) 
          paren = args[3]
          unless (s_matched = src.scan(term_re)) || paren.equal?( nil) || 
                    (s_matched = src.scan(paren_re)) then
            @string_buffer << "\\"
          end
        end
      elsif s_ch.equal?( ?/ ) && regexp && term[0]._not_equal?( ?/ )
        src.advance(1)  
        cres = "\\/"   # This path possibly not in ruby_parser2.0.2
      else
        paren = args[3]
        term = args[1]
        t = Regexp.escape( term )
        x = Regexp.escape(paren) if paren && paren != "\000"
        re = if awords then
               /[^#{t}#{x}\#\0\\\n\ \t]+|./ # |. to pick up whatever  
				# Bug in Ryan's code , added the \t
             else
               /[^#{t}#{x}\#\0\\]+|./
             end

        s_matched = src.scan( re )
        cres = s_matched
        num_eols += cres._count_eols 
        symbol = (func & STR_FUNC_SYMBOL)._not_equal?( 0)
        if symbol && cres._contains_string( '\\0') # symbol && cres =~ /\0/
          rb_compile_error "symbol cannot contain '\\0'" 
        end
      end
      cres ||= s_matched
      @string_buffer << cres
      @line_num += num_eols
    end # until eos #  ]

    cres ||= s_matched
    if src.eos?
      cres = :tEOF 
    end
    if @mydebug
      puts "  end of tokadd_string at byte #{src.pos} "
      puts "     string_buffer #{@string_buffer.inspect} "
    end
    return cres
  end # ]

  #def gsub_string_ESC_RE(s_matched )
  #  # in separate method to avoid ref to $1 in yylex method
  #  s_matched[1..-2].gsub(ESC_RE) { unescape( $1 ) }
  #end

  def unescape( s)
    r = UNESCAPE_TABLE[s]
    if r
      return r 
    end

    case s
    when /^[0-7]{1,3}/ then
      $&.to_i(8).chr
    when /^x([0-9a-fA-F]{1,2})/ then
      $1.to_i(16).chr
    when /^M-(.)/ then
      ($1[0] | 0x80).chr   # c[0].ord
    when /^(C-|c)(.)/ then
      ($2[0] & 0x9f).chr   # c[0].ord
    when /^[McCx0-9]/ then
      rb_compile_error("Invalid escape character syntax")
    else
      s
    end
  end

  def warning(str)
    puts str
  end

  ##
  # Returns the next token. Also sets yy_val is needed.
  #
  def advance  # old name  was yylex # [
    @yacc_value = nil

    clex_strterm = @lex_strterm
    if clex_strterm
      # inline yylex_string
      tk = if clex_strterm[0].equal?( :heredoc) then
              self.heredoc( *clex_strterm )
            else
              self.parse_string( *clex_strterm)
            end
      if tk.equal?( :tSTRING_END ) || tk.equal?( :tREGEXP_END) then
        @lex_strterm = nil
        @lex_state   = Expr_end
      end
      return tk
    end

    c = ''
    space_seen = false
    src = @src_scanner

    command_state = @command_start
    @command_start = false

    last_state = @lex_state

    while true # [
      s_ch = src.skip_vt_white
      tok_start_offset = src.pos
      if s_ch >= 256
        space_seen = true   # whitespace was skipped
        s_ch = s_ch - 256
        if s_ch.equal?(256) 
          # hit EOF on current region
          regions = @src_regions
          rofs = regions.size - 1
          if rofs >= 0
            # pop top of the src_regions stack and resume lexing 
            a_region = regions[rofs]
            @line_num = a_region.line_num
            src_limit = a_region.limit 
            src.set_pos_limit( a_region.offset, a_region.limit )  
            regions.size=( rofs )
            if @mydebug
              puts "region EOF, resuming: line #{@line_num} offset #{a_region.offset} limit #{a_region.limit}"
            end
            next
          end 
          @yacc_value = :tEOF 
          return :tEOF
        end
      end
      s_ch_type = src.type_of_ch(s_ch)
      if (s_ch_type >= CTYPE_DIGIT) # [
        if s_ch_type.equal?( CTYPE_DIGIT) 
          return parse_number
        else
          # must be CTYPE_LC_ALPHA , CTYPE_UC_ALPHA or CTYPE_UNDERSCORE
          if s_ch.equal?( ?_ )
            if src.beginning_of_line? && src.check_advance(/\__END__(\n|\Z)/) then
              # TODO initialize  transient constant value of DATA  (Pickaxe page 337)
              #     to be remainder of source string after line with __END__,
              #     ONLY IF current source file is the main program file.
              @yacc_value = :tEOF
              return :tEOF
            end
            s_matched = src.scan(/\_\w*/)
          else
            s_matched = src.scan(/\w+/)
          end
          return process_token(s_matched, command_state, tok_start_offset)
        end
      elsif s_ch_type >= CTYPE_EOF  # ] [
        if s_ch_type.equal?( CTYPE_SIGN) #  src.scan(/[+-]/))  # [
          src.advance(1)
          if s_ch.equal?( ?+ ) 
            utype = :tUPLUS
            type = :tPLUS
            sign = :'+'
          else
            utype = :tUMINUS
            type = :tMINUS
            sign = :'-'
          end
          s_ch = src.peek_ch 

          clex_state = @lex_state
          if (clex_state & Expr_IS_fname_dot)._not_equal?( 0)  then
            @lex_state = Expr_arg
            if s_ch.equal?( ?@ )   # src.scan(/@/)
              src.advance(1)
              @yacc_value = RpNameToken.new( :"#{sign}@" , tok_start_offset)
              return utype
            else
              @yacc_value = RpNameToken.new( sign , tok_start_offset)
              return type
            end
          end

          if s_ch.equal?( ?= ) #  src.scan(/\=/) 
            src.advance(1)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( sign , tok_start_offset)
            return :tOP_ASGN
          end

          is_arg = (clex_state & Expr_IS_argument)._not_equal?(0)
          if ( (clex_state & Expr_IS_beg_mid)._not_equal?( 0) ||
               ( is_arg && space_seen && 
                    ! src.ch_is_white(s_ch)) )   #  !src.check(/\s/))) 
            #if is_arg	# shutoff warning, Trac 567
            #  arg_ambiguous
            #end
            @lex_state = Expr_beg
            
            if src.ch_is_digit(s_ch)  #  src.check(/\d/) then
              if utype.equal?( :tUPLUS) then
                return self.parse_number
              else
                @yacc_value = RpNameToken.new( sign , tok_start_offset)
                return :tUMINUS_NUM
              end
            end
            @yacc_value = RpNameToken.new( sign , tok_start_offset)
            if is_arg
              return type	# Fix Trac 567
            else
              return utype  
            end
          end

          @lex_state = Expr_beg
          @yacc_value = RpNameToken.new( sign , tok_start_offset)
          return type
        else  			# ] [ 
          # must be CTYPE_EOF
          src.advance(1)   #   src.scan(/\004|\032|\000/
          @yacc_value = :tEOF 
          return :tEOF
        end # ]
      else  # ] [
        # must be CTYPE_OTHER
        if s_ch.equal?( ?# ) #  [
          src.advance_to_eol     
          # if at EOF it will be handled at top of loop
          next
        elsif s_ch.equal?( ?\n ) # ] [
          lf_count = 1		 # count LF 
          s_ch = src.advance_peek(1) 
          while s_ch.equal?( ?\n )    # src.scan(/\n+/)
            lf_count += 1             # consume consecutive empty lines
            s_ch = src.advance_peek(1)
          end
          @line_num = @line_num + lf_count

          if (@lex_state & Expr_IS_beg_fname_dot_class)._not_equal?(0) then
            next
          end

          @command_start = true
          @lex_state = Expr_beg
          return :tNL                  
                                      
        elsif s_ch.equal?( ?) )       #  src.scan(/[\]\)\}]/)) # ] [
          src.advance(1) 
          @cond.lexpop
          @cmdarg.lexpop
          @lex_state = Expr_end
          @yacc_value = :")"
          return :tRPAREN               # [
        elsif s_ch.equal?( ?] )        #  src.scan(/[\]\)\}]/)) # ] [
          src.advance(1) 
          @cond.lexpop
          @cmdarg.lexpop
          @lex_state = Expr_end
          @yacc_value = RpNameToken.new( :']' , tok_start_offset )
          return  :tRBRACK		# 
        elsif s_ch.equal?( ?} )      #  src.scan(/[\]\)\}]/))# ] [
          src.advance(1) 
          @cond.lexpop
          @cmdarg.lexpop
          @lex_state = Expr_end
          @yacc_value = :"}"
 	  return :tRCURLY
        elsif s_ch.equal?( ?. ) then #  src.check(/\./)# ] [
          eq_code = src.at_equalsCONSEC_DOTS   # '...' -->0 , '..' -->1  else 2
          if eq_code.equal?( 0 )  # src.scan(/\.\.\./) then
            src.advance(3)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"..." , tok_start_offset )
            return :tDOT3
          elsif eq_code.equal?( 1 )  #  src.scan(/\.\./) then
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :".." , tok_start_offset )
            return :tDOT2
          elsif src.scan(/\.\d/) then
            rb_compile_error "no .<digit> floating literal anymore put 0 before dot"
          else #  if src.scan(/\./) then
            src.advance(1)
            @lex_state = Expr_dot
            @yacc_value = :"."
            return :tDOT
          end
        elsif s_ch.equal?( ?, )  # src.scan(/\,/) # ] [
          src.advance(1)
          @lex_state = Expr_beg
          @yacc_value = :","
          return :tCOMMA
        elsif s_ch.equal?( ?( ) #  src.scan(/\(/) # ] [
          src.advance(1)
          result = :tLPAREN2
          @command_start = true
          clex_state = @lex_state
          if (clex_state & Expr_IS_beg_mid)._not_equal?( 0)  then
            result = :tLPAREN
          elsif space_seen then
            if clex_state.equal?( Expr_cmdArg) then
              result = :tLPAREN_ARG
            elsif clex_state.equal?( Expr_arg) then
              msg = "don't put space before argument parentheses, near line #{@line_num}"
              if @mydebug ; msg << " (A)" ; end 
              warning(msg)
              result = :tLPAREN2
            end
          end

          self.expr_beg_push( RpNameToken.new( :"(", tok_start_offset) )

          return result
        elsif s_ch.equal?( ?= )  # src.check(/\=/)  # ] [
          eq_code = src.at_equalsCONSEC_EQUALS#  '==='-->0, '=='-->1, '=~'-->2, '=>'-->3 else 4 
          if eq_code.equal?( 0 ) # src.scan(/\=\=\=/) then
            src.advance(3)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"===" , tok_start_offset )
            return :tEQQ
          elsif eq_code.equal?( 1 )  #  src.scan(/\=\=/) then
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"==" , tok_start_offset )
            return :tEQ
          elsif eq_code.equal?( 2 )  # src.scan(/\=~/) then
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"=~" , tok_start_offset )
            return :tMATCH
          elsif eq_code.equal?( 3 ) # src.scan(/\=>/) then
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = :"=>"
            return :tASSOC
          else #  if src.scan(/\=/) then
            # was_begin_of_line and scan(/begin(?=\s)/) 
            s_ch = src.advance_peek(1)
            if s_ch.equal?( ?b ) and 
               (src.peek_ahead(-2).equal?( ?\n ) or src.pos.equal?(1)) and 
               src.check_advance(/begin(?=\s)/) 
              # handle multi-line comment  begin= ... =end  
              unless src.check_advance(/.*?\n=end\s*(\n|\z)/m) then
                rb_compile_error("embedded document meets end of file")
              end
              next
            else
              self.fix_arg_lex_state
              @yacc_value = RpNameToken.new( :'=' , tok_start_offset) 
              return :tEQL
            end
          end
        elsif s_ch.equal?( ?" ) # src.scan(/\"/)     # ] [
          if (s_matched = src.scan(/\"( |\t|\w)*\"/o)) 
            # A simple double quoted string containing space, tab, alpha or digit chars
            @yacc_value = s_matched[1, s_matched.length - 2 ]  #exclude the quotes
            @lex_state = Expr_end
            new_pos = src.pos
            return :t_STRING
          else
            # lex a double quoted string the hard way
            src.advance(1)
            @lex_strterm = STRTERM_DQUOTE  
            @yacc_value = "\""
            return :tSTRING_BEG
          end
        elsif (s_ch.equal?( ?@ )) and (s_matched = src.scan(/\@\@?\w*/)) then  #  ] [
          first_dig_ch = s_matched[1] 
          if first_dig_ch._not_equal?(nil) and src.ch_is_digit( first_dig_ch) # @token  =~ /\@\d/
            rb_compile_error "'#{s_matched}' is not allowed as a variable name" 
          end
          return process_token(s_matched, command_state, tok_start_offset)
        elsif (s_ch.equal?( ?: ))  # ] [
          clex_state = @lex_state
          next_ch  = src.peek_ahead(1)
          if next_ch.equal?( ?: ) # src.scan(/\:\:/)
            src.advance(2)
            if ( (clex_state & Expr_IS_beg_mid_class)._not_equal?(0) ||
                 ( (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen )) then
              @lex_state = Expr_beg
              @yacc_value = :"::"
              return :tCOLON3
            end
            @lex_state = Expr_dot
            @yacc_value = :"::"
            return :tCOLON2
          end
          if (clex_state & Expr_IS_end_endarg).equal?( 0)
            if src.check_advance(/:([a-zA-Z_]\w*(?:[?!]|=(?!>))?)/) then
              @yacc_value = src[1]
              @lex_state = Expr_end
              return :tSYMBOL
            end
            if next_ch.equal?( ?- ) || next_ch.equal?( ?+ )
              src.advance(1)
              if s_matched = src.scan(/[+-]@/)
                @yacc_value = s_matched     
                @lex_state = Expr_end
                return :tSYMBOL
              else
                src.advance(-1)
              end
            end
          end
          #  elsif src.scan(/\:/) then 
	  src.advance(1)
	  # ?: / then / when
	  s_ch = src.peek_ch
	  if ( (clex_state & Expr_IS_end_endarg)._not_equal?(0) ||
	       src.ch_is_white(s_ch) )         # src.check(/\s/) then
	    @lex_state = Expr_beg
	    @yacc_value = :":"
	    return :tCOLON
	  end
	  if s_ch.equal?( ?' ) # when src.scan(/\'/) then
	    src.advance(1)
	    @lex_strterm = STRTERM_SSYM 
	  elsif s_ch.equal?( ?\" ) #  when src.scan(/\"/) then
	    src.advance(1)
	    @lex_strterm = STRTERM_DSYM 
	  end
	  @lex_state = Expr_fname
	  @yacc_value = :":"
	  return :tSYMBEG
        elsif s_ch.equal?( ?[ ) # src.scan(/\[/) then    # ] # ] [
          src.advance(1)
          result = :tLBRACK_STR  # was "["
          clex_state = @lex_state
          if (clex_state & Expr_IS_fname_dot)._not_equal?(0) then
            @lex_state = Expr_arg          # [
            if src.peek_ch.equal?( ?] )
              if src.peek_ahead(1).equal?( ?= )  #   # when src.scan(/\]\=/)   
                src.advance(2)
                @yacc_value = RpNameToken.new( :"[]=" , tok_start_offset)
                return :tASET            #      
              else                 # when src.scan(/\]/) 
                src.advance(1)
                @yacc_value = RpNameToken.new( :"[]" , tok_start_offset)
                return :tAREF
              end
            else
              rb_compile_error "unexpected '['"   
            end
          elsif (clex_state & Expr_IS_beg_mid)._not_equal?(0) then 
            result = :tLBRACK
          elsif (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen then 
            result = :tLBRACK
          end

          self.expr_beg_push( :"[" )

          return result
        elsif s_ch.equal?( ?')     # ] [
          if (s_matched = src.scan(/\'(\\.|[^\'])*\'/)) 
            unless s_matched[-1].equal?(  ?' )
              rb_compile_error 'unterminated single-quoted string meets end of file'
            end
            @yacc_value = s_matched[1..-2].gsub(/\\\\/, "\\").gsub(/\\'/, "'")
            @lex_state = Expr_end
            new_pos = src.pos
            @line_num = @line_num + src.count_eols(tok_start_offset, new_pos-1)  # count LFs
            return :t_STRING
          else 
            src.advance(1)
            if src.scan(/.*\'/)
              rb_compile_error 'logic error in parsing single quoted string'
            else
              rb_compile_error 'unterminated single-quoted string meets end of file'
            end
          end
        elsif s_ch.equal?( ?| ) # src.check(/\|/) # ] [
          eq_code = src.at_equalsCONSEC_OR   # [ '||=' , '||' , '|=' ]
          if eq_code.equal?(0) # if src.scan(/\|\|\=/) 
            src.advance(3)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"||" , tok_start_offset )
            return :tOP_ASGN
          elsif eq_code.equal?(1) #  src.scan(/\|\|/) 
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = :"||"
            return :tOROP
          elsif eq_code.equal?(2) #   src.scan(/\|\=/) 
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"|" , tok_start_offset)
            return :tOP_ASGN
          else
            src.advance(1)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"|" , tok_start_offset)
            return :tPIPE
          end
        elsif s_ch.equal?( ?{ ) #  src.scan(/\{/) then   # ] [
          src.advance(1)
          clex_state = @lex_state
          result = if (clex_state & Expr_IS_argument_end)._not_equal?(0) then
                     :tLCURLY      #  block (primary)
                   elsif clex_state.equal?( Expr_endArg) then
                     :tLBRACE_ARG  #  block (expr)
                   else
                     :tLBRACE      #  hash
                   end

          self.expr_beg_push( "{" )

          return result
        elsif s_ch.equal?( ?* ) #  src.check(/\*/) # ] [
          eq_code = src.at_equalsCONSEC_STAR # [ '**=' , '**' , '*=' ]
          if eq_code.equal?( 0 ) # src.scan(/\*\*=/) 
            src.advance(3)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"**" , tok_start_offset)
            return :tOP_ASGN
          elsif eq_code.equal?( 1 ) # src.scan(/\*\*/) 
            src.advance(2)
            @yacc_value = RpNameToken.new( :"**" , tok_start_offset)
            self.fix_arg_lex_state
            return :tPOW
          elsif eq_code.equal?( 2 ) # src.scan(/\*\=/) 
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"*" , tok_start_offset)
            return :tOP_ASGN
          else  # src.scan(/\*/) 
            src.advance(1) 
            clex_state = @lex_state
            result = if (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen &&
                          ! src.peek_is_white    #  && src.check(/\S/) 
                       if @mydebug
                         warning("`*' interpreted as argument prefix")  # MRI 1.8.6 does not warn
                       end
                       :tSTAR
                     elsif (clex_state & Expr_IS_beg_mid)._not_equal?(0) then
                       :tSTAR
                     else
                       :tSTAR2
                     end
            @yacc_value = RpNameToken.new( :"*" , tok_start_offset)
            self.fix_arg_lex_state

            return result
          end
        elsif s_ch.equal?( ?! ) # src.check(/\!/) # ] [
          next_ch = src.peek_ahead(1)
          if next_ch.equal?( ?= )  # src.scan(/\!\=/)
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( "!=", tok_start_offset)
            return :tNEQ
          elsif next_ch.equal?( ?~ ) # # src.scan(/\!~/)
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"!~" , tok_start_offset )
            return :tNMATCH
          else #  src.scan(/\!/) 
            src.advance(1) 
            @lex_state = Expr_beg
            @yacc_value = :"!"
            return :tBANG
          end
        elsif s_ch.equal?( ?< ) # src.check(/\</) then  # ] [
          eq_code = src.at_equalsCONSEC_LT # [ '<=>' , '<=' , '<<=' , '<<'  ]
          if eq_code.equal?( 0) # src.scan(/\<\=\>/) 
            src.advance(3) 
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"<=>" , tok_start_offset )
            return :tCMP
          elsif eq_code.equal?( 1 ) # src.scan(/\<\=/) 
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"<=" , tok_start_offset)
            return :tLEQ
          elsif eq_code.equal?( 2 ) # src.scan(/\<\<\=/) 
            src.advance(3) 
            self.fix_arg_lex_state
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"\<\<" , tok_start_offset)
            return :tOP_ASGN
          elsif eq_code.equal?( 3 ) # src.scan(/\<\</) 
            src.advance(2)
            clex_state = @lex_state
            if ( (clex_state & Expr_IS_end_dot_endarg_class).equal?(0) &&  # none of 4 
                ( (! (clex_state & Expr_IS_argument)._not_equal?(0)) || space_seen )) then
              tok = self.heredoc_identifier( src )
              if tok then
                return tok  # found start of heredoc
              end
            end
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"\<\<" , tok_start_offset )
            return :tLSHFT
          else  #  if src.scan(/\</) 
            src.advance(1)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"<" , tok_start_offset )
            return :tLT
          end
        elsif s_ch.equal?( ?> ) # src.check(/\>/) # ] [
          eq_code = src.at_equalsCONSEC_GT  # [ >= , >>= , >> ]
          if eq_code.equal?( 0) # src.scan(/\>\=/) 
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :">=" , tok_start_offset )
            return :tGEQ
          elsif eq_code.equal?( 1) # src.scan(/\>\>=/) 
            src.advance(3)
            self.fix_arg_lex_state
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :">>" , tok_start_offset)
            return :tOP_ASGN
          elsif eq_code.equal?( 2) # src.scan(/\>\>/) 
            src.advance(2)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :">>" , tok_start_offset )
            return :tRSHFT
          else #  if src.scan(/\>/) 
            src.advance(1)
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :">" , tok_start_offset )
            return :tGT
          end
        elsif s_ch.equal?( ?` ) # src.scan(/\`/) # ] [
          src.advance(1)
          clex_state = @lex_state
          if clex_state.equal?( Expr_fname)  then
            @lex_state = Expr_end
            @yacc_value = RpNameToken.new( :"`" , tok_start_offset)
            return :tBACK_REF2
          elsif clex_state.equal?( Expr_dot)  then
            @lex_state = if command_state then
                               Expr_cmdArg
                             else
                               Expr_arg
                             end
            @yacc_value = RpNameToken.new( :"`" , tok_start_offset)
            return :tBACK_REF2
          end
          @lex_strterm = STRTERM_XQUOTE 
          @yacc_value = RpNameToken.new( :"`" , tok_start_offset )
          return :tXSTRING_BEG
        elsif s_ch.equal?( ?? ) # src.scan(/\?/)  # ] [
          src.advance(1)
          clex_state = @lex_state
          if (clex_state & Expr_IS_end_endarg)._not_equal?( 0) then
            @lex_state = Expr_beg
            @yacc_value = :"?"
            return :tEH
          end

          s_ch = src.peek_ch 
          if s_ch.equal?(nil)
            rb_compile_error "incomplete character syntax" # EOF
          end
          if src.ch_is_vt_white__or_eol(s_ch)    # src.check(/\s|\v/) then
            unless (clex_state & Expr_IS_argument)._not_equal?(0)
              ekey = s_ch
              c2 = CHAR_LIT_VT_WHITE_ERRS[ekey] 
              if c2 then
                warning("invalid character syntax; use ?\\" + c2)
              else
                raise('logic error in LIT_VT_WHITE_ERRS  in lexer')
              end
            end
            # ternary
            @lex_state = Expr_beg
            @yacc_value = :"?"
            return :tEH
          elsif src.check(/\w(?=\w)/) then # ternary, also
            @lex_state = Expr_beg
            @yacc_value = :"?"
            return :tEH
          end
          if s_ch.equal?( ?\\  ) #  src.check_advance(/\\/) then
            src.advance(1)
            cstr = self.read_escape
            res_ch = cstr[0]     # .ord
          else
            src.advance(1)
            res_ch = s_ch
          end
          @lex_state = Expr_end
          @yacc_value = res_ch & 0xff
          return :tINTEGER
        elsif s_ch.equal?( ?& ) # src.check(/\&/)   # ] [
          eq_code = src.at_equalsCONSEC_AND #  [ '&&=' , '&&' , '&=' ]
          if eq_code.equal?( 0) # src.scan(/\&\&\=/) 
            src.advance(3)
            @yacc_value = RpNameToken.new( :"&&" , tok_start_offset)
            @lex_state = Expr_beg
            return :tOP_ASGN
          elsif eq_code.equal?( 1) # src.scan(/\&\&/) 
            src.advance(2)
            @lex_state = Expr_beg
            @yacc_value = :"&&"
            return :tANDOP
          elsif eq_code.equal?( 2) # src.scan(/\&\=/) 
            src.advance(2)
            @yacc_value = RpNameToken.new( :"&" , tok_start_offset)
            @lex_state = Expr_beg
            return :tOP_ASGN
          else # src.scan(/&/) 
            src.advance(1)
            clex_state = @lex_state
            result = if (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen &&
                         ! src.peek_is_white  # ! src.check(/\s/) then
                       if @mydebug
                         warning("`&' interpreted as argument prefix")  # MRI 1.8.6 does not warn
                       end
                       @yacc_value = :"&"
                       :tAMPER
                     elsif (clex_state & Expr_IS_beg_mid)._not_equal?( 0) then
                       @yacc_value = :"&"
                       :tAMPER
                     else
                       @yacc_value = RpNameToken.new( :'&' , tok_start_offset )
                       :tAMPER2
                     end

            self.fix_arg_lex_state
            return result
          end
        elsif s_ch.equal?( ?/ ) # src.scan(/\//)  # 
          src.advance(1)
          clex_state = @lex_state
          if (clex_state & Expr_IS_beg_mid)._not_equal?( 0) then
            @lex_strterm = STRTERM_REGEXP 
            @yacc_value = RpNameToken.new( :"/" , tok_start_offset)
            return :tREGEXP_BEG
          end

          s_ch = src.peek_ch
          if s_ch.equal?( ?= ) # src.scan(/\=/) 
            src.advance(1)
            @yacc_value = RpNameToken.new( :"/" , tok_start_offset)
            @lex_state = Expr_beg
            return :tOP_ASGN
          end

          if (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen then
            if src.ch_is_white(s_ch)  # unless src.scan(/\s/)
              src.advance(1)
            else            
              arg_ambiguous
              @lex_strterm = STRTERM_REGEXP 
              @yacc_value = RpNameToken.new( :"/" , tok_start_offset)
              return :tREGEXP_BEG
            end
          end

          self.fix_arg_lex_state
          @yacc_value = RpNameToken.new( :"/" , tok_start_offset)

          return :tDIVIDE
        elsif s_ch.equal?( ?^ ) 
          src.advance(1)
          if src.peek_ch.equal?( ?= ) # src.scan(/\^=/) 
            src.advance(1)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"^" , tok_start_offset)
            return :tOP_ASGN
          else                        # src.scan(/\^/ 
            self.fix_arg_lex_state
            @yacc_value = RpNameToken.new( :"^" , tok_start_offset )
            return :tCARET
          end
        elsif s_ch.equal?( ?; ) # src.scan(/\;/) 
          src.advance(1)
          @command_start = true
          @lex_state = Expr_beg
          @yacc_value = :";"
          return :tSEMI
        elsif s_ch.equal?( ?~ ) # src.scan(/\~/) 
          src.advance(1)
          clex_state = @lex_state
          if (clex_state & Expr_IS_fname_dot)._not_equal?( 0) then
            src.check_advance(/@/)
          end

          self.fix_arg_lex_state
          @yacc_value = RpNameToken.new( :"~" , tok_start_offset )

          return :tTILDE
        elsif s_ch.equal?( ?\\ ) # src.scan(/\\/) 
          src.advance(1)
          if src.peek_ch.equal?( ?\n ) # src.scan(/\n/) 
            src.advance(1)
            space_seen = true 
            next
          end
          rb_compile_error "bare backslash only allowed before newline"
        elsif s_ch.equal?( ?% ) # src.scan(/\%/) 
          src.advance(1)
          clex_state = @lex_state
          if (clex_state & Expr_IS_beg_mid)._not_equal?( 0) then
            return parse_quote
          end

          if src.peek_ch.equal?( ?= ) # src.scan(/\=/) 
            src.advance(1)
            @lex_state = Expr_beg
            @yacc_value = RpNameToken.new( :"%" , tok_start_offset)
            return :tOP_ASGN
          end

          if (clex_state & Expr_IS_argument)._not_equal?(0) && space_seen && 
                 ! src.peek_is_white #  ! src.check(/\s/) 
            return parse_quote
          end

          self.fix_arg_lex_state
          @yacc_value = RpNameToken.new( :"%" , tok_start_offset)

          return :tPERCENT
        elsif s_ch.equal?( ?$ ) #  src.check(/\$/)) # ] [
          if (s_matched = src.scan(/(\$_)(\w+)/)) then
            @lex_state = Expr_end
            return process_token(s_matched, command_state, tok_start_offset)
          elsif (s_matched = src.scan(/\$_/)) then
            @lex_state = Expr_end
            @yacc_value = RpNameToken.new(s_matched, tok_start_offset)
            return :tGVAR
          elsif (s_matched = src.scan(/\$[~*$?!@\/\\;,.=:<>\"]|\$-\w?/)) then
            @lex_state = Expr_end
            @yacc_value = RpNameToken.new(s_matched, tok_start_offset)
            return :tGVAR
          elsif (s_matched = src.scan(/\$([\&\`\'\+])/)) then
            @lex_state = Expr_end
            # Explicit reference to these vars as symbols...
            if last_state.equal?( Expr_fname) then
              @yacc_value = RpNameToken.new(s_matched, tok_start_offset)
              return :tGVAR
            else
              @yacc_value = src[1].__as_symbol
              return :tBACK_REF
            end
          elsif (s_matched = src.scan(/\$([1-9]\d*)/)) then
            @lex_state = Expr_end
            if last_state.equal?( Expr_fname) then
              @yacc_value = RpNameToken.new(s_matched, tok_start_offset)
              return :tGVAR
            else
              @yacc_value = src[1].to_i
              return :tNTH_REF
            end
          elsif (s_matched = src.scan(/\$0/)) then
            @lex_state = Expr_end
            return process_token(s_matched, command_state, tok_start_offset)
          elsif src.check_advance(/\$\W|\$\z/) then 
            #@parser.raise_error( 'lexer unexpected match /\$\W|\$\z/ ' )   # TODO202 remove?
            rb_compile_error "unexpected whitespace after '$' "  
          elsif (s_matched = src.scan(/\$\w+/))
            @lex_state = Expr_end
            return process_token(s_matched, command_state, tok_start_offset)
          end
        else # ] [
          s_matched = src.scan(/\W/)   # must be some other non-word char
          rb_compile_error "Invalid char #{s_matched.inspect} in expression"
        end   # ]
      end # end of must be CTYPE_OTHER # ]
    end  # ]  end of while true 
  end # ] end of advance

  def process_token(ttoken, command_state, tok_start_offset) # [
    # method result is  a token type such as  :tIDENTIFIER

    src = @src_scanner

    #if ttoken =~ /^\w/ && (s_matched = src.scan(/[\!\?](?!=)/))
    #  ttoken << s_matched 
    #end
    tt_first_ch = ttoken[0]
    next_ch = src.peek_ch
    if next_ch.equal?( ?! ) || next_ch.equal?( ?? )
      if src.ch_is_digit_alpha_uscore( tt_first_ch ) 
	third_ch = src.peek_ahead(1)
	if third_ch._not_equal?( ?= )
	  src.advance(1)
	  ttoken << next_ch
	end
      end
    end 

    result = nil
    clex_state = @lex_state
    last_state = clex_state

    # case tk
    if tt_first_ch.equal?( ?$ ) # when /^\$/ then
      @lex_state = Expr_end
      y_value = RpNameToken.new( ttoken, tok_start_offset)
      @yacc_value = y_value
      result = :tGVAR
    elsif tt_first_ch.equal?( ?@ )   #  
      if ttoken[1].equal?( ?@ )  # when /^@@/ then
        @lex_state = Expr_end
        y_value = RpNameToken.new( ttoken, tok_start_offset)
        @yacc_value = y_value
        result = :tCVAR
      else                   # when /^@/ then
        @lex_state = Expr_end
        y_value = RpNameToken.new( ttoken, tok_start_offset)
        @yacc_value = y_value
        result = :tIVAR
      end
    else # [
      tt_last_ch = ttoken[ttoken.size - 1]
      if tt_last_ch.equal?( ?! ) || tt_last_ch.equal?( ?? )  # ttoken =~ /[!?]$/
        result = :tFID
      else
        if clex_state.equal?( Expr_fname) then
          # ident=, not =~ => == or followed by =>
          # TODO202 test lexing of a=>b vs a==>b
          if src.peek_ch.equal?( ?= )
            if (s_matched = src.scan(/=(?:(?![~>=])|(?==>))/)) then
              result = :tIDENTIFIER
              ttoken << s_matched
            end
          end
        end
        # result ||= if ttoken =~ /^[A-Z]/ then :tCONSTANT else :tIDENTIFIER end
        if result.equal?( nil )
          if src.ch_is_uc_alpha(tt_first_ch) 
             result = :tCONSTANT
          else
             result = :tIDENTIFIER
          end
        end
      end

      unless clex_state.equal?( Expr_dot) then # [
        # See if it is a reserved word.
        #   was keyword = Keyword.keyword[ttoken]
        kwarr = @keyword_table.at_casesens_otherwise(ttoken, true, nil)

        if kwarr._not_equal?(nil) 
          # clex_state holds "old state" and we update @lex_state
          #   with new state to be valid after return
          kw_state = kwarr[2] # was keyword.state
          kw_id_zero = kwarr[0] # was keyword.id0 
          if kw_state >= 0
            @lex_state = kw_state
            @yacc_value = ttoken
            if kw_id_zero.equal?( :kELSE )
              @last_else_src_offset = tok_start_offset # for hints and warnings
            end
          else
            @lex_state  =  0 - kw_state

            if kw_id_zero.equal?( :kDO ) then
              @command_start = true
              @yacc_value = RpNameToken.new( ttoken , tok_start_offset)
              return :kDO_COND  if @cond.is_in_state
              return :kDO_BLOCK if @cmdarg.is_in_state && clex_state._not_equal?( Expr_cmdArg)
              return :kDO_BLOCK if clex_state.equal?( Expr_endArg )
              return :kDO
            end
            if kw_id_zero.equal?( :kDEF) 
              # need a byte offset and line number for :kDEF
              @yacc_value = DefnNameToken.new( ttoken, tok_start_offset, @line_num )
            else
              # need a byte offset
              @yacc_value = RpNameToken.new( ttoken, tok_start_offset)
            end
          end

          if clex_state.equal?( Expr_beg )
            return kw_id_zero 
          end
          kw_id_one = kwarr[1] # was keyword.id1
          if ( kw_id_zero._not_equal?(  kw_id_one ) )
            @lex_state = Expr_beg 
          end
          return kw_id_one
        end
      end # ]


      if (clex_state & Expr_IS_beg_mid_dot_arg_cmdarg)._not_equal?( 0)  then
        if command_state then
          @lex_state = Expr_cmdArg
        else
          @lex_state = Expr_arg
        end
      else
        @lex_state = Expr_end
      end
      y_value = RpNameToken.new( ttoken , tok_start_offset )
      @yacc_value = y_value
    end # ]

    # unless  ttoken.__as_symbol.equal?( y_value.symval )   # uncomment for debugging
    #   puts 'Inconsistent ttoken'  
    #   nil.pause
    # end
    #
    if (last_state._not_equal?( Expr_dot)) && @parser.env[ y_value.symval ].equal?( :lvar)
       @lex_state = Expr_end 
    end
    return result
  end # ]

end

end # MagRp
