# Computes the derived month amounts of Credit Card Payment categories
# (YNAB docs: "Handling Credit Cards in YNAB: An Overview", "Handling
# Credit Card Overspending: An Overview", "Credit Card Payments: A
# Guide", "When Your Credit Card Payment Category is Red"):
#
# - Funded credit spending moves funds from the spending category into
#   the card's payment category. Ready to Assign is unaffected: the money
#   was already assigned to the spending category. The funded portion of
#   a category's credit spending is what remains once the month's
#   shortfall is attributed cash-first (MonthCategory.overspend_split):
#   credit spending is covered before cash, so only the shortfall beyond
#   the month's cash outflows is credit overspending.
# - Overspent credit spending does NOT move: it becomes card
#   underfunding (the payment category simply does not receive it).
# - Payments (transfers into the credit account) spend the payment
#   category's Available; paying more than Available makes the category
#   red, which is cash overspending handled by the generic month rules.
# - Users may also assign directly to the payment category; those stored
#   budgeted amounts are handled by the generic month-category flow.
#
# Amounts are derived at read time from stored month aggregates and
# transactions. Retroactive edits recalculate the result. Date/creation
# tie-breaking is a deterministic implementation choice, not a claim of
# verified YNAB ordering for multi-card backdated edits.
class CreditCardFunding
  def initialize(budget)
    @budget = budget
  end

  # Net movement into the card's payment category for the month, in
  # milliunits: funded credit spending in, payments out.
  def payment_activity(account_id, month)
    funded_by_account(month)[account_id].to_i - payments_by_account(month)[account_id].to_i
  end

  # Plan months (first-of-month dates) up to `upto` in which the card has
  # funding or payment activity.
  def active_months(account_id, upto:)
    scope = Transaction.where(budget_id: @budget.id, account_id: account_id, deleted: false)
      .where("date <= ?", upto.end_of_month)
    months = scope.where("category_id IS NOT NULL OR transfer_account_id IS NOT NULL").pluck(:date)
    months += scope.where(id: SubTransaction.where(deleted: false).where.not(category_id: nil).select(:transaction_id)).pluck(:date)
    months.map { |date| date.beginning_of_month }.uniq
  end

  private
    def funded_by_account(month)
      @funded_by_account ||= {}
      @funded_by_account[month] ||= compute_funded(month)
    end

    def payments_by_account(month)
      @payments_by_account ||= {}
      @payments_by_account[month] ||= Transaction
        .where(budget_id: @budget.id, account_id: credit_account_ids, deleted: false, date: month..month.end_of_month)
        .where(transfer_account_id: cash_account_ids)
        .where("amount > 0")
        .group(:account_id).sum(:amount)
    end

    def compute_funded(month)
      result = Hash.new(0)
      return result if credit_account_ids.empty?

      @budget.categories.not_deleted.where(internal: false, payment_account_id: nil).includes(:month_categories).find_each do |category|
        entries = category.month_categories.select { |entry| entry.month <= month }.sort_by(&:month)
        start = 0
        entries.each do |entry|
          break if entry.month >= month
          start += entry.budgeted.to_i + entry.activity.to_i
          start = 0 if start.negative?
        end
        current = entries.find { |entry| entry.month == month }
        next if current.nil?

        credit_activity = ledger.category_credit_activity(category.id, month)
        credit_total = -credit_activity

        balance_end = start + current.budgeted.to_i + current.activity.to_i
        credit_short = 0
        if balance_end.negative?
          _cash, credit_short = MonthCategory.overspend_split(balance_end, current.activity, credit_activity)
        end
        pool = credit_total - credit_short

        # Deterministic replay approximates the documented purchase move ("YNAB
        # automatically moves the money to cover the purchase" -
        # Handling Credit Cards in YNAB: An Overview): the category's
        # funded pool covers this month's credit transactions in entry
        # order (date, then creation); a categorized refund moves money
        # back into the pool (and out of that card's payment category)
        # where it lands.
        entries = []
        Transaction.not_deleted.where(budget_id: @budget.id, account_id: credit_account_ids, date: month..month.end_of_month).includes(:sub_transactions).each do |transaction|
          if transaction.sub_transactions.not_deleted.any?
            transaction.sub_transactions.not_deleted.each do |sub|
              entries << [ transaction.date, sub.created_at, transaction.account_id, ledger.sub_credit_amount(sub) ] if sub.category_id == category.id
            end
          elsif transaction.category_id == category.id
            entries << [ transaction.date, transaction.created_at, transaction.account_id, ledger.credit_amount(transaction) ]
          end
        end
        # Refunds reduce net funded spending but also release funds for
        # other purchases. Start with the gross covered pool; subtract
        # refunds once, during replay (including refund-only months).
        pool += entries.sum { |_date, _created_at, _account_id, amount| [ amount, 0 ].max }
        pool = [ pool, 0 ].max
        entries.sort_by! { |date, created_at, _account_id, _amount| [ date, created_at ] }
        entries.each do |_date, _created_at, account_id, amount|
          if amount.negative?
            covered = [ -amount, pool ].min
            result[account_id] += covered
            pool -= covered
          else
            result[account_id] -= amount
          end
        end
      end
      result
    end

    def ledger
      @ledger ||= CreditCardLedger.new(@budget)
    end

    def cash_account_ids
      @cash_account_ids ||= @budget.accounts.not_deleted.where(type: %w[checking savings cash], on_budget: true).pluck(:id)
    end

    def credit_account_ids
      @credit_account_ids ||= @budget.accounts.not_deleted.select(&:credit?).map(&:id)
    end
end
