# Historical card balances distinguish cash held on a positive card from
# new borrowing. YNAB docs: Credit Cards with a Positive Balance and
# Credit Card Cash Advances. Starting balance is the stored account
# balance less its live transaction total; transaction edits therefore
# recalculate classification rather than freezing the original effects.
class CreditCardLedger
  def initialize(budget)
    @budget = budget
  end

  def credit_amount(transaction, amount = transaction.amount)
    amount = amount.to_i
    return amount if amount >= 0

    -entries.fetch(transaction.id, {}).fetch(:new_debt, -amount)
  end

  def sub_credit_amount(sub)
    return sub.amount if sub.amount >= 0

    remaining = entries.fetch(sub.transaction_id, {}).fetch(:new_debt, 0)
    sub.parent_transaction.sub_transactions.not_deleted.order(:created_at, :id).each do |part|
      next unless part.amount.negative?
      portion = [ -part.amount, remaining ].min
      return -portion if part.id == sub.id
      remaining -= portion
    end
    0
  end

  def category_credit_activity(category_id, month)
    total = 0
    transactions.each do |transaction|
      next unless transaction.month == month
      if transaction.sub_transactions.not_deleted.any?
        transaction.sub_transactions.not_deleted.each do |sub|
          total += sub_credit_amount(sub) if sub.category_id == category_id
        end
      elsif transaction.category_id == category_id
        total += credit_amount(transaction)
      end
    end
    total
  end

  def debt_inflow_through(month)
    entries.values.select { |entry| entry[:month] <= month }.sum { |entry| entry[:debt_inflow] }
  end

  private
    def entries
      @entries ||= begin
        result = {}
        transactions.group_by(&:account_id).each do |account_id, rows|
          account = rows.first.account
          balance = account.balance.to_i - rows.sum(&:amount)
          rows.sort_by { |t| [ t.date, t.created_at, t.id ] }.each do |transaction|
            before = balance
            balance += transaction.amount.to_i
            new_debt = [ [ -balance, 0 ].max - [ -before, 0 ].max, 0 ].max
            inflow = 0
            if transaction.transfer_account && cash_account_ids.include?(transaction.transfer_account_id)
              if transaction.amount.negative?
                inflow = new_debt
              else
                inflow = [ balance, 0 ].max - [ before, 0 ].max
              end
            end
            result[transaction.id] = { new_debt: new_debt, debt_inflow: inflow, month: transaction.month }
          end
        end
        result
      end
    end

    def transactions
      @transactions ||= Transaction.not_deleted.where(budget_id: @budget.id, account_id: credit_account_ids)
        .includes(:account, :transfer_account, :sub_transactions).to_a
    end

    def credit_account_ids
      @credit_account_ids ||= @budget.accounts.not_deleted.where(type: Account::CREDIT_TYPES).pluck(:id)
    end

    def cash_account_ids
      @cash_account_ids ||= @budget.accounts.not_deleted.where(type: %w[checking savings cash], on_budget: true).pluck(:id)
    end
end
