# Parses an Assigned amount typed in the budget grid (issue #56 CAT-EXPR-01):
# a plain number or arithmetic such as 10+5*2 (= 20). Exact rational math, no
# eval. Anything it cannot read is rejected with a message, never saved as 0.
# The result must be a whole number of milliunits (at most 3 decimals) so
# nothing is silently rounded.
class AssignedExpression
  LIMIT = 1_000_000_000_000
  Result = Struct.new(:milliunits, :error)

  def self.parse(text)
    new(text.to_s).parse
  end

  def initialize(text)
    @text = text.strip
    @pos = 0
  end

  def parse
    return Result.new(nil, "Enter an amount such as 100 or 10+5*2.") if @text.empty?

    value = expression
    skip
    return failure unless @pos == @text.length
    return Result.new(nil, "That expression has a division by zero.") if value.nil?

    milli = value * 1000
    return Result.new(nil, "The result must be a whole number of thousandths, such as 12.345.") unless milli.denominator == 1
    return Result.new(nil, "That amount is too large.") if milli.abs >= LIMIT

    Result.new(milli.to_i, nil)
  rescue ZeroDivisionError
    Result.new(nil, "That expression has a division by zero.")
  rescue ArgumentError
    failure
  end

  private
    def failure
      Result.new(nil, "Could not read \"#{@text.truncate(40)}\". Use numbers with + - * / and parentheses, such as 10+5*2.")
    end

    def skip
      @pos += 1 while @text[@pos] == " "
    end

    def expression
      value = term
      loop do
        skip
        op = @text[@pos]
        break unless op == "+" || op == "-"
        @pos += 1
        rhs = term
        value = op == "+" ? value + rhs : value - rhs
      end
      value
    end

    def term
      value = factor
      loop do
        skip
        op = @text[@pos]
        break unless op == "*" || op == "/"
        @pos += 1
        rhs = factor
        raise ZeroDivisionError if op == "/" && rhs.zero?
        value = op == "*" ? value * rhs : value / rhs
      end
      value
    end

    def factor
      skip
      char = @text[@pos]
      if char == "-"
        @pos += 1
        -factor
      elsif char == "("
        @pos += 1
        value = expression
        skip
        raise ArgumentError unless @text[@pos] == ")"
        @pos += 1
        value
      else
        match = /\A\d+(\.\d{1,9})?/.match(@text[@pos..])
        raise ArgumentError unless match
        @pos += match[0].length
        Rational(match[0])
      end
    end
    end
