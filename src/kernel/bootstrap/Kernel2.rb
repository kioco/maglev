module Kernel
  # file Kernel2.rb  , parts of kernel that must be deferred to later
  #  in the bootstrap

  def binding
    # usually the block argument is synthesized by the parser.
    # this case is used to create the top-level binding.
    Binding.new( self._binding_ctx(0), self, nil )
  end

  def binding(&blk)
    Binding.new( self._binding_ctx(0), self , blk)
  end

  def block_given?(&blk)
    # this implementation present so   send   will work.
    block_given?   # implemented by parser, not a recursive send
  end

  def lambda(&blk)
    Proc.new_lambda(&blk)
  end

  def proc(&blk)
    Proc.new(&blk)
  end

  def rand(n=nil)
    if n
      RandomInstance.next(n) - 1
    else
      RandomInstance.next
    end
  end

  def srand(number=nil)
    if number.equal?(nil)
      number = Time.now.to_i
    else
      number = number.to_i
    end
    old_seed = RandomInstance.seed
    RandomInstance.seed(number)
    old_seed
  end

  module_function :debugger
end
