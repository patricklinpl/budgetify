# Reads a bank CSV and plans an import into one account. Nothing is written:
# the result says which rows would be new, which would match a transaction the
# user entered by hand, and which would be skipped as already imported.
#
# [reference] Source: YNAB's File-Based Import help page
# (https://support.ynab.com/en_us/file-based-import-a-guide-Bkj4Sszyo.md).
# Documented, not observed in the reference app:
# - Columns map to Date, Payee, Memo, Outflow and Inflow. Options: no header
#   row, swap Inflow and Outflow, and include or leave out rows dated before
#   the account start date.
# - Categories and splits are not imported.
# - An imported row matches a manually entered transaction when the amounts are
#   exactly equal and the dates are within ten days of each other.
# - A row with the exact same date and amount as one already imported is
#   skipped. A row that was imported and then deleted is skipped too.
# [engineering] My choices, not observed or documented: the header names that
# count as each field, the explicit date format (YNAB does not say how it picks
# one, so the caller must name it), reading the account start date from its
# opening balance transaction, matching an exact date and amount on a manual
# transaction as a match (not a skip), the nearest date winning a match and each
# manual transaction matching one row at most, the import id format, and
# counting rows as duplicates of each other only when the file repeats them.
class CsvImport
  FIELDS = %i[date payee memo outflow inflow].freeze
  HEADER_NAMES = {
    date: %w[date transactiondate postingdate posteddate],
    payee: %w[payee description name merchant],
    memo: %w[memo notes note reference],
    outflow: %w[outflow debit withdrawal withdrawals paidout],
    inflow: %w[inflow credit deposit deposits paidin]
  }.freeze
  DATE_FORMATS = { iso: "%Y-%m-%d", us: "%m/%d/%Y", eu: "%d/%m/%Y" }.freeze
  DATE_PATTERNS = { iso: %r{\A\d{4}-\d{1,2}-\d{1,2}\z}, us: %r{\A\d{1,2}/\d{1,2}/\d{4}\z}, eu: %r{\A\d{1,2}/\d{1,2}/\d{4}\z} }.freeze
  MATCH_DAYS = 10
  # The caller passes the file text, so the caller bounds its size. A larger
  # text is reported as a problem and not read. [engineering] The cap is my
  # choice (it is not a YNAB limit); read-and-plan holds the whole file in memory.
  MAX_BYTES = 5_000_000
  # [engineering] A plan lists every row on one page, so a file with more rows than
  # this is reported and not read. The cap is my choice, not a YNAB limit.
  MAX_ROWS = 5_000

  Row = Struct.new(:line, :date, :payee, :memo, :amount, :import_id, :status, :reason, :matched_transaction, :before_start, keyword_init: true)
  Problem = Struct.new(:line, :message)
  Result = Struct.new(:rows, :problems, :mapping, keyword_init: true) do
    def counts = rows.group_by(&:status).transform_values(&:size)
  end

  def self.plan(text, account:, date_format:, amount_format: :point, mapping: nil, no_header: false, swap: false, include_before_start: true)
    new(text, account, date_format, mapping, no_header, swap, include_before_start, amount_format).plan
  end

  def initialize(text, account, date_format, mapping, no_header, swap, include_before_start, amount_format = :point)
    raise ArgumentError, "amount_format must be :point or :comma" unless %i[point comma].include?(amount_format)
    @amount_format = amount_format
    raise ArgumentError, "date_format must be one of #{DATE_FORMATS.keys.inspect}" unless DATE_FORMATS.key?(date_format)
    @text = text.to_s
    @account = account
    @format = DATE_FORMATS.fetch(date_format)
    @pattern = DATE_PATTERNS.fetch(date_format)
    @mapping = mapping
    @no_header = no_header
    @swap = swap
    @include_before_start = include_before_start
  end

  def plan
    refusal = unreadable
    return Result.new(rows: [], problems: [ Problem.new(nil, refusal) ], mapping: {}) if refusal
    records, closed = self.class.read(@text.delete_prefix("\uFEFF"))
    unless closed
      return Result.new(rows: [], problems: [ Problem.new(nil, "A quoted cell is never closed, so the rest of the file cannot be read") ], mapping: {})
    end
    if records.size > MAX_ROWS + 1
      return Result.new(rows: [], problems: [ Problem.new(nil, "The file has more than #{MAX_ROWS} rows. Split it into smaller files") ], mapping: {})
    end
    header = @no_header ? nil : records.shift
    mapping = @mapping || detect(header, records.first)
    problems = []
    missing = FIELDS.first(1) - mapping.keys
    missing << :amount if !(mapping.key?(:outflow) || mapping.key?(:inflow))
    return Result.new(rows: [], problems: [ Problem.new(nil, "No column found for #{missing.join(', ')}") ], mapping: mapping) if missing.any?

    rows = records.each_with_index.filter_map do |cells, index|
      line = index + (@no_header ? 1 : 2)
      next if cells.all? { |cell| cell.strip.empty? }
      build_row(cells, line, mapping, problems)
    end
    rows = rows.reject(&:before_start) unless @include_before_start
    classify(rows)
    Result.new(rows: rows, problems: problems, mapping: mapping)
  end

  # Minimal CSV reader: quoted cells, doubled quotes, commas and line breaks
  # inside quotes, CRLF or LF line ends.
  def self.records(text) = read(text).first

  # Same as records, plus whether every quote was closed.
  def self.read(text)
    records = []
    row = []
    cell = +""
    quoted = false
    pending = nil # a quote seen inside quotes: closes the cell or is a doubled quote
    after_cr = false
    text.each_char do |c|
      if after_cr
        after_cr = false
        next if c == "\n"
      end
      if pending
        pending = nil
        if c == '"' then cell << '"'; next
        else quoted = false
        end
      end
      if quoted
        if c == '"' then pending = true
        else cell << c
        end
      elsif c == '"' then quoted = true
      elsif c == "," then row << cell; cell = +""
      elsif c == "\n" || c == "\r"
        after_cr = c == "\r"
        row << cell; records << row; row = []; cell = +""
      else cell << c
      end
    end
    quoted = false if pending
    (row << cell; records << row) unless cell.empty? && row.empty?
    [ records, !quoted ]
  end

  # Milliunits from text such as "12.34", "$1,234.5" or "-3". Nil when it is not
  # a plain amount with at most three decimals. A comma is read only as a
  # thousands separator in groups of three digits ("1,234", "12,345.60"); "12,34"
  # is not read, because a decimal comma would be off by a factor of 100.
  def self.milliunits(text)
    t = text.to_s.strip
    sign = t.start_with?("-", "+") ? t.slice!(0) : ""
    cleaned = sign + t.delete_prefix("$")
    cleaned = cleaned.delete(" ")
    plain = cleaned.match?(/\A[+-]?(\d+(\.\d{0,3})?|\.\d{1,3})\z/)
    grouped = cleaned.match?(/\A[+-]?\d{1,3}(,\d{3})+(\.\d{0,3})?\z/)
    return nil unless plain || grouped
    (BigDecimal(cleaned.delete(",")) * 1000).to_i
  end

  private

  def detect(header, first_record)
    mapping = {}
    if header
      header.each_with_index do |name, index|
        key = name.to_s.downcase.gsub(/[^a-z]/, "")
        field = HEADER_NAMES.find { |_, names| names.include?(key) }&.first
        mapping[field] = index if field && !mapping.key?(field)
      end
    else
      FIELDS.each_with_index { |field, index| mapping[field] = index if first_record && index < first_record.size }
    end
    mapping
  end

  def build_row(cells, line, mapping, problems)
    date = parse_date(cells[mapping[:date]])
    unless date
      problems << Problem.new(line, "Date is missing or not in the chosen format")
      return nil
    end
    outflow = amount_cell(cells, mapping[:outflow], "Outflow", line, problems)
    inflow = amount_cell(cells, mapping[:inflow], "Inflow", line, problems)
    return nil if outflow == :bad || inflow == :bad
    if outflow.nil? && inflow.nil?
      problems << Problem.new(line, "No amount in the Outflow or Inflow cell")
      return nil
    end
    if outflow.to_i.nonzero? && inflow.to_i.nonzero?
      problems << Problem.new(line, "Both Outflow and Inflow have an amount")
      return nil
    end
    amount = inflow.to_i - outflow.to_i
    amount = -amount if @swap
    Row.new(line: line, date: date, payee: cell(cells, mapping[:payee]), memo: cell(cells, mapping[:memo]), amount: amount,
      before_start: start_date && date < start_date)
  end

  # Outflow and Inflow hold positive amounts. A negative one, or one in
  # parentheses, is reported and not guessed at: its meaning depends on the bank.
  def amount_cell(cells, index, name, line, problems)
    return nil unless index
    text = cells[index].to_s.strip
    return nil if text.empty?
    value = self.class.milliunits(@amount_format == :comma ? text.tr(".,", ",.") : text)
    if value.nil?
      problems << Problem.new(line, text.match?(/\A\(.*\)\z/) ? "#{name} is in parentheses, which is not read" : "#{name} is not a plain number")
      :bad
    elsif value.negative?
      problems << Problem.new(line, "#{name} is negative, which is not read")
      :bad
    else
      value
    end
  end

  # The year must have four digits: a two-digit year would parse as year 26.
  def parse_date(text)
    text = text.to_s.strip
    return nil unless text.match?(@pattern)
    Date.strptime(text, @format)
  rescue ArgumentError
    nil
  end

  def unreadable
    return "The file is larger than #{MAX_BYTES} bytes and was not read" if @text.bytesize > MAX_BYTES
    text = @text.encoding == Encoding::UTF_8 ? @text : @text.dup.force_encoding(Encoding::UTF_8)
    return "The file is not valid UTF-8 text" unless text.valid_encoding?
    @text = text
    nil
  end

  def cell(cells, index)
    index ? cells[index].to_s.strip.presence : nil
  end

  def start_date
    return @start_date if defined?(@start_date)
    @start_date = @account.budget.transactions.where(account_id: @account.id, opening_balance: true, deleted: false).minimum(:date)
  end

  def classify(rows)
    existing = @account.budget.transactions.where(account_id: @account.id, transfer_account_id: nil).to_a.group_by(&:amount)
    taken = Set.new
    seen = Hash.new(0)
    rows.each do |row|
      key = [ row.amount, row.date ]
      seen[key] += 1
      row.import_id = "CSV:#{row.amount}:#{row.date.iso8601}:#{seen[key]}"
      candidates = existing.fetch(row.amount, [])
      same = candidates.select { |t| t.amount == row.amount && t.date == row.date && t.import_id.present? }
      if same.any? { |t| t.import_id == row.import_id } || same.size >= seen[key]
        row.status = :skipped
        row.reason = "Already imported: same date and amount"
        next
      end
      candidate = candidates.select { |t| !t.deleted && t.import_id.blank? && t.matched_transaction_id.nil? && t.amount == row.amount && !taken.include?(t.id) && (t.date - row.date).abs <= MATCH_DAYS }
        .min_by { |t| [ (t.date - row.date).abs, t.id ] }
      if candidate
        taken << candidate.id
        row.status = :matched
        row.matched_transaction = candidate
        row.reason = "Matches a transaction you entered: same amount, #{(candidate.date - row.date).abs.to_i} day(s) apart"
      else
        row.status = :new
        row.reason = "No matching transaction"
      end
    end
  end
end
