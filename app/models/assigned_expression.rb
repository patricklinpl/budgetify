# Server side of the shared currency expression rules (issue #56 CAT-EXPR-01,
# issue #70 FRM-02). It mirrors app/javascript/controllers/lib/currency_expression.js
# so the browser field and the server agree: "$" and spaces are ignored, only
# digits and + - * / ( ) . , are allowed, commas are thousands separators only,
# and a result with fractions of a cent (0.004, 10/3) is rejected so displayed
# and stored amounts always agree. Precision is whole cents whatever the plan's
# display digits are; display format never changes arithmetic. Exact rational
# math, no eval. Invalid input is rejected with a message and never becomes 0.
class AssignedExpression
  LIMIT = 1_000_000_000_000
  COMMA_MESSAGE = "Check commas: use 1,234.56 (commas only as thousands separators)".freeze
  Result = Struct.new(:milliunits, :error)

  class Invalid < StandardError; end

  def self.parse(text)
    new(text.to_s).parse
  end

  def initialize(text)
    @src = text.gsub(/[$\s]/, "")
    @pos = 0
  end

  def parse
    return Result.new(nil, "Enter an amount") if @src.empty?
    return Result.new(nil, "Use numbers and + - * / only") unless @src.match?(%r{\A[0-9.,+\-*/()]+\z})

    value = expression
    raise Invalid, "Not a valid amount" unless @pos == @src.length

    cents = value * 100
    raise Invalid, "Use at most 2 decimal places (whole cents)" unless cents.denominator == 1
    raise Invalid, "That amount is too large" if cents.abs * 10 >= LIMIT

    Result.new(cents.to_i * 10, nil)
  rescue Invalid => e
    Result.new(nil, e.message)
  end

  private
    def peek
      @src[@pos]
    end

    def expression
      value = term
      while peek == "+" || peek == "-"
        op = @src[@pos]
        @pos += 1
        rhs = term
        value = op == "+" ? value + rhs : value - rhs
      end
      value
    end

    def term
      value = factor
      while peek == "*" || peek == "/"
        op = @src[@pos]
        @pos += 1
        rhs = factor
        raise Invalid, "Cannot divide by zero" if op == "/" && rhs.zero?
        value = op == "*" ? value * rhs : value / rhs
      end
      value
    end

    def factor
      case peek
      when "-"
        @pos += 1
        -factor
      when "+"
        @pos += 1
        factor
      when "("
        @pos += 1
        value = expression
        raise Invalid, "Not a valid amount" unless peek == ")"
        @pos += 1
        value
      else
        number
      end
    end

    def number
      match = /\A((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)/.match(@src[@pos..])
      unless match
        raise Invalid, COMMA_MESSAGE if peek == ","
        raise Invalid, "Check the decimal point: use a number like 12.50" if peek == "."
        raise Invalid, "Not a valid amount"
      end
      @pos += match[0].length
      raise Invalid, COMMA_MESSAGE if peek == ","
      raise Invalid, "Check the decimal point: use one decimal point with digits after it, like 12.50" if peek == "."
      raise Invalid, COMMA_MESSAGE if peek&.match?(/\d/)
      Rational(match[0].delete(",").sub(/\A\./, "0."))
    end
end
