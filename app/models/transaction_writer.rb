# The write path for transactions: field assignment, split children,
# linked-transfer mirror and the account and category amount effects. The
# YNAB API controller and the browser editor (#60) both write through it so
# there is one definition of a saved transaction. Lookups are scoped to the
# plan. An invalid input raises Invalid, whose message is the user-facing
# reason; callers inside a database transaction roll back on it.
class TransactionWriter
  class Invalid < StandardError; end

  FUTURE_DATE = "The transaction date cannot be in the future.".freeze
  BAD_DATE = "The transaction date is not valid; use ISO format (e.g. 2016-12-01).".freeze
  SUB_TOTAL = "The subtransactions must add up to the transaction amount.".freeze

  def initialize(plan)
    @plan = plan
  end

  # An unsaved transaction from permitted attributes, with unsaved split
  # children. Nothing is written.
  def build(attributes)
    raise Invalid, FUTURE_DATE if attributes["date"].blank?
    date = parse_date(attributes["date"])
    raise Invalid, FUTURE_DATE if date > Date.current

    account = @plan.accounts.not_deleted.find_by(public_id: attributes["account_id"])
    raise Invalid, "The account_id is not valid." if account.nil?

    transaction = @plan.transactions.new(account: account)
    assign(transaction, attributes)
    raise Invalid, transaction.errors.full_messages.to_sentence unless transaction.valid?
    raise Invalid, SUB_TOTAL unless sub_amounts_valid?(attributes, transaction.amount)

    build_sub_transactions(transaction, attributes["subtransactions"])
    transaction
  end

  # Saves a built transaction and applies its effects.
  def persist_new!(transaction)
    raise Invalid, transaction.errors.full_messages.to_sentence unless transaction.save

    sync_transfer!(transaction)
    apply_all_amounts!(transaction, +1)
    transaction
  end

  # Reverses the old effects, assigns the attributes, saves, re-syncs the
  # transfer pair and applies the new effects. Run it inside a database
  # transaction so a failure after the reversal leaves balances untouched.
  def update!(transaction, attributes, rebuild_subs:)
    check_date!(attributes["date"])
    raise Invalid, SUB_TOTAL if rebuild_subs && !sub_amounts_valid?(attributes, transaction.amount)

    apply_all_amounts!(transaction, -1)
    assign(transaction, attributes)
    raise Invalid, transaction.errors.full_messages.to_sentence unless transaction.save

    rebuild_sub_transactions(transaction, attributes["subtransactions"]) if rebuild_subs
    sync_transfer!(transaction)
    apply_all_amounts!(transaction, +1)
    transaction
  end

  def destroy!(transaction)
    apply_all_amounts!(transaction, -1)
    transaction.transfer_transaction&.update!(deleted: true)
    transaction.update!(deleted: true)
  end

  def check_date!(value)
    return if value.blank?

    raise Invalid, FUTURE_DATE if parse_date(value) > Date.current
  end

  # Split transactions require the subtransaction amounts to sum to the
  # parent amount (spec: NewTransaction.subtransactions).
  def sub_amounts_valid?(attributes, parent_amount)
    entries = attributes["subtransactions"]
    return true if entries.nil?

    total = entries.sum { |entry| (entry.respond_to?(:[]) ? entry["amount"].to_i : 0) }
    total == (attributes.key?("amount") && !attributes["amount"].nil? ? attributes["amount"].to_i : parent_amount.to_i)
  end

  # Assigns permitted save fields, resolving payee by id or creating by
  # payee_name, category by id, and transfer accounts via the transfer
  # payee (spec: NewTransaction / SaveTransaction).
  def assign(transaction, attributes)
    transaction.date = attributes["date"] if attributes["date"].present?
    transaction.amount = attributes["amount"] if attributes.key?("amount") && !attributes["amount"].nil?
    transaction.memo = attributes["memo"] if attributes.key?("memo")
    transaction.cleared = attributes["cleared"] if attributes["cleared"].present?
    transaction.approved = attributes["approved"] unless attributes["approved"].nil?
    transaction.flag_color = attributes["flag_color"].presence
    transaction.flag_name = attributes["flag_name"]
    transaction.import_id = attributes["import_id"] if attributes["import_id"].present?
    transaction.import_payee_name = attributes["import_payee_name"] if attributes["import_payee_name"].present?
    transaction.import_payee_name_original = attributes["import_payee_name_original"] if attributes["import_payee_name_original"].present?

    if attributes["transfer_account_id"].present?
      transfer_account = @plan.accounts.not_deleted.find_by(public_id: attributes["transfer_account_id"])
      raise Invalid, "The transfer_account_id is not valid." if transfer_account.nil?

      transaction.transfer_account = transfer_account
      transaction.payee = transfer_account.transfer_payee
    elsif attributes["payee_id"].present?
      payee = @plan.payees.not_deleted.find_by(public_id: attributes["payee_id"])
      raise Invalid, "The payee_id is not valid." if payee.nil?

      transaction.payee = payee
      transaction.transfer_account = payee.transfer_account
    elsif attributes["payee_name"].present?
      transaction.payee = @plan.payees.not_deleted.find_or_create_by!(name: attributes["payee_name"], budget: @plan)
      transaction.transfer_account = nil
    elsif attributes.key?("payee_id")
      transaction.payee = nil
      transaction.transfer_account = nil
    end

    if attributes["category_id"].present?
      category = @plan.categories.not_deleted.find_by(public_id: attributes["category_id"])
      raise Invalid, "The category_id is not valid." if category.nil?

      # Credit Card Payment categories are system-managed; a supplied one
      # is ignored, leaving the category unchanged (spec:
      # SaveTransaction.category_id).
      transaction.category = category unless category.payment?
    elsif attributes.key?("category_id")
      transaction.category = nil
    end
    transaction
  end

  def build_sub_transactions(transaction, entries)
    return if entries.blank?

    entries.each do |entry|
      entry = entry.respond_to?(:permit) ? entry.permit!.to_h : entry.to_h
      sub = transaction.sub_transactions.build(amount: entry["amount"], memo: entry["memo"])
      if entry["payee_id"].present?
        sub.payee = @plan.payees.not_deleted.find_by(public_id: entry["payee_id"])
      elsif entry["payee_name"].present?
        sub.payee = @plan.payees.not_deleted.find_or_create_by!(name: entry["payee_name"], budget: @plan)
      end
      if entry["category_id"].present?
        # Credit Card Payment categories are ignored if supplied (spec:
        # SaveSubTransaction.category_id).
        sub_category = @plan.categories.not_deleted.find_by(public_id: entry["category_id"])
        sub.category = sub_category unless sub_category&.payment?
      end
    end
  end

  def rebuild_sub_transactions(transaction, entries)
    return if entries.nil?

    transaction.sub_transactions.each(&:destroy!)
    build_sub_transactions(transaction, entries)
    transaction.sub_transactions.each { |sub| sub.save! if sub.new_record? }
  end

  # Transfers auto-create and sync the paired transaction in the other
  # account (spec: transfer_account_id / transfer_transaction_id).
  def sync_transfer!(transaction)
    transfer_account = transaction.transfer_account
    pair = transaction.transfer_transaction
    if transfer_account.nil?
      # Unlinked from a transfer: the mirror is soft-deleted (its amounts
      # were already reversed by the caller) rather than left live with a
      # stale amount.
      if pair
        pair.update!(transfer_transaction: nil, deleted: true)
        transaction.update_columns(transfer_transaction_id: nil)
      end
      return
    end

    pair ||= @plan.transactions.new(account: transfer_account)
    pair.assign_attributes(
      account: transfer_account,
      date: transaction.date,
      amount: -transaction.amount.to_i,
      cleared: transaction.cleared,
      approved: transaction.approved,
      payee: @plan.payees.not_deleted.find_by(transfer_account_id: transaction.account.id),
      transfer_account: transaction.account
    )
    pair.save!
    pair.update_columns(transfer_transaction_id: transaction.id) if pair.transfer_transaction_id != transaction.id
    transaction.update_columns(transfer_transaction_id: pair.id) if transaction.transfer_transaction_id != pair.id
  end

  # Applies (or reverses, with sign -1) this transaction's account and
  # category effects, its subtransactions', and its transfer pair's.
  def apply_all_amounts!(transaction, sign)
    transaction.reload
    transaction.apply_amounts!(sign)
    transaction.sub_transactions.not_deleted.each { |sub| apply_sub_amounts(sub, sign) }
    transaction.transfer_transaction&.apply_amounts!(sign)
  end

  private
    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise Invalid, BAD_DATE
    end

    def apply_sub_amounts(sub, sign)
      return if sub.category.nil?

      delta = sub.amount.to_i * sign
      month_category = sub.category.month_category_for(sub.parent_transaction.month)
      month_category.activity = month_category.activity.to_i + delta
      month_category.credit_activity = month_category.credit_activity.to_i + delta if sub.parent_transaction.account.credit?
      month_category.save!
    end
end
