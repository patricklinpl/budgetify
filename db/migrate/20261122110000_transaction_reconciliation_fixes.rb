class TransactionReconciliationFixes < ActiveRecord::Migration[8.1]
  def up
    add_column :month_categories, :credit_activity, :bigint, null: false, default: 0
    add_column :sub_transactions, :knowledge, :bigint, null: false, default: 0
    add_index :sub_transactions, :knowledge

    # Backfill credit-backed activity from the transactions and
    # subtransactions that produced each month's category activity (spec:
    # MonthSummary.to_be_budgeted). Split parents carry no category
    # activity of their own; their subtransactions do.
    MonthCategory.reset_column_information
    Transaction.where(deleted: false).where.not(category_id: nil).includes(:account, :sub_transactions).find_each do |transaction|
      next if transaction.sub_transactions.loaded? && transaction.sub_transactions.any? { |sub| !sub.deleted? }
      next unless transaction.account.credit?

      month_category = MonthCategory.find_by(category_id: transaction.category_id, month: transaction.date.beginning_of_month)
      month_category&.update_columns(credit_activity: month_category.credit_activity + transaction.amount)
    end
    SubTransaction.where(deleted: false).where.not(category_id: nil).includes(parent_transaction: :account).find_each do |sub|
      next unless sub.parent_transaction.account.credit?

      month_category = MonthCategory.find_by(category_id: sub.category_id, month: sub.parent_transaction.date.beginning_of_month)
      month_category&.update_columns(credit_activity: month_category.credit_activity + sub.amount)
    end

    # Stamp existing subtransactions with their parent transaction's
    # knowledge so delta requests treat them consistently (spec:
    # last_knowledge_of_server).
    SubTransaction.find_each { |sub| sub.update_columns(knowledge: sub.parent_transaction.knowledge) }

    # month_categories.balance was written but never read (balances are
    # recomputed by the serializers).
    remove_column :month_categories, :balance, :bigint
  end

  def down
    add_column :month_categories, :balance, :bigint
    remove_column :sub_transactions, :knowledge
    remove_column :month_categories, :credit_activity
  end
end
