# Parses an Assigned amount typed in the budget grid (issue #56 CAT-EXPR-01):
# a plain number or arithmetic such as 10+5*2 (= 20). Exact rational math, no
# eval. Anything it cannot read is rejected with a message, never saved as 0.
# The result must be a whole number of the plan's currency units at its
# decimal_digits (whole cents for USD, the same rule as the #70 form fields:
# 0.004 and 10/3 are rejected), so displayed and stored amounts always agree.
class AssignedExpression
  LIMIT = 1_000_000_000_000
  Result = Struct.new(:milliunits, :error)

  def self.parse(text, digits: 2)
    new(text.to_s, digits).parse
  end

  def initialize(text, digits = 2)
    @text = text.strip
    @digits = digits.to_i.clamp(0, 3)
    @pos = 0
  end

  def parse
    return Result.new(nil, "Enter an amount such as 100 or 10+5*2.") if @text.empty?

    value = expression
    skip
    return failure unless @pos == @text.length
    return Result.new(nil, "That expression has a division by zero.") if value.nil?

    milli = value * 1000
    unless milli.denominator == 1 && (milli % (10**(3 - @digits))).zero?
      example = @digits.zero? ? "12" : "12.#{'3456'[0, @digits]}"
      return Result.new(nil, "The result must have at most #{@digits} decimal #{@digits == 1 ? 'place' : 'places'} for this plan's currency, such as #{example}.")
    end
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
# Used by the budget grid (Users::CategoriesController).
