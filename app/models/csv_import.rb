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
  MATCH_DAYS = 10

  Row = Struct.new(:line, :date, :payee, :memo, :amount, :import_id, :status, :matched_transaction, :before_start, keyword_init: true)
  Problem = Struct.new(:line, :message)
  Result = Struct.new(:rows, :problems, :mapping, keyword_init: true) do
    def counts = rows.group_by(&:status).transform_values(&:size)
  end

  def self.plan(text, account:, date_format:, mapping: nil, no_header: false, swap: false, include_before_start: true)
    new(text, account, date_format, mapping, no_header, swap, include_before_start).plan
  end

  def initialize(text, account, date_format, mapping, no_header, swap, include_before_start)
    raise ArgumentError, "date_format must be one of #{DATE_FORMATS.keys.inspect}" unless DATE_FORMATS.key?(date_format)
    @text = text.to_s.delete_prefix("\uFEFF")
    @account = account
    @format = DATE_FORMATS.fetch(date_format)
    @mapping = mapping
    @no_header = no_header
    @swap = swap
    @include_before_start = include_before_start
  end

  def plan
    records = self.class.records(@text)
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
  def self.records(text)
    records = []
    row = []
    cell = +""
    quoted = false
    chars = text.chars
    i = 0
    while i < chars.size
      c = chars[i]
      if quoted
        if c == '"' && chars[i + 1] == '"' then cell << '"'; i += 1
        elsif c == '"' then quoted = false
        else cell << c
        end
      elsif c == '"' then quoted = true
      elsif c == "," then row << cell; cell = +""
      elsif c == "\n" || c == "\r"
        i += 1 if c == "\r" && chars[i + 1] == "\n"
        row << cell; records << row; row = []; cell = +""
      else cell << c
      end
      i += 1
    end
    (row << cell; records << row) unless cell.empty? && row.empty?
    records
  end

  # Milliunits from text such as "12.34", "$1,234.5" or "-3". Nil when it is not
  # a plain amount with at most three decimals.
  def self.milliunits(text)
    cleaned = text.to_s.strip.delete("$,").delete(" ")
    return nil unless cleaned.match?(/\A[+-]?(\d+(\.\d{0,3})?|\.\d{1,3})\z/)
    (BigDecimal(cleaned) * 1000).to_i
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
    outflow = amount_cell(cells, mapping[:outflow], line, problems)
    inflow = amount_cell(cells, mapping[:inflow], line, problems)
    return nil if outflow == :bad || inflow == :bad
    amount = inflow.to_i - outflow.to_i
    amount = -amount if @swap
    Row.new(line: line, date: date, payee: cell(cells, mapping[:payee]), memo: cell(cells, mapping[:memo]), amount: amount,
      before_start: start_date && date < start_date)
  end

  def amount_cell(cells, index, line, problems)
    return nil unless index
    text = cells[index].to_s.strip
    return nil if text.empty?
    value = self.class.milliunits(text)
    return value.abs if value
    problems << Problem.new(line, "Amount is not a plain number")
    :bad
  end

  def parse_date(text)
    Date.strptime(text.to_s.strip, @format)
  rescue ArgumentError
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
    existing = @account.budget.transactions.where(account_id: @account.id, transfer_account_id: nil).to_a
    taken = Set.new
    seen = Hash.new(0)
    rows.each do |row|
      key = [ row.amount, row.date ]
      seen[key] += 1
      row.import_id = "CSV:#{row.amount}:#{row.date.iso8601}:#{seen[key]}"
      same = existing.select { |t| t.amount == row.amount && t.date == row.date && t.import_id.present? }
      if same.any? { |t| t.import_id == row.import_id } || same.size >= seen[key]
        row.status = :skipped
        next
      end
      candidate = existing.select { |t| !t.deleted && t.import_id.blank? && t.matched_transaction_id.nil? && t.amount == row.amount && !taken.include?(t.id) && (t.date - row.date).abs <= MATCH_DAYS }
        .min_by { |t| [ (t.date - row.date).abs, t.id ] }
      if candidate
        taken << candidate.id
        row.status = :matched
        row.matched_transaction = candidate
      else
        row.status = :new
      end
    end
  end
end
