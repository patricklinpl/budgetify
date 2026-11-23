module AppShellHelper
  SHELL_ACCOUNT_GROUPS = [
    [ "CASH", %w[checking savings cash] ],
    [ "CREDIT", %w[creditCard lineOfCredit] ],
    [ "LOANS", %w[mortgage autoLoan studentLoan personalLoan medicalDebt otherDebt] ],
    [ "TRACKING", %w[otherAsset otherLiability] ]
  ].freeze

  # Sidebar groups for a plan: open accounts only, empty groups omitted,
  # each with its subtotal (milliunits). Unmapped types are not shown.
  def shell_account_groups(budget)
    accounts = budget.accounts.not_deleted.where(closed: false).order(:name).to_a
    SHELL_ACCOUNT_GROUPS.filter_map do |label, types|
      members = accounts.select { |account| types.include?(account.type) }
      next if members.empty?

      { label: label, accounts: members, total: members.sum(&:balance) }
    end
  end

  # Account balances are stored in milliunits. Display format is a placeholder
  # until plan currency settings land (#54 PLAN-03).
  def shell_money(milliunits)
    number_to_currency(milliunits / 1000.0)
  end

  def shell_money_class(milliunits)
    milliunits.negative? ? "money money--negative" : "money"
  end
end
