require "test_helper"

# The shared transaction write path (#60). The API integration tests cover it
# through HTTP; these pin the service itself, which the browser editor uses
# too: plain objects in, balances and activity out, Invalid for bad input.
class TransactionWriterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "writer@example.com", password: "password123")
    @plan = @user.budgets.create!(name: "Writer plan")
    @checking = @plan.accounts.create!(name: "Checking", type: "checking")
    @savings = @plan.accounts.create!(name: "Savings", type: "savings")
    group = @plan.category_groups.create!(name: "Everyday")
    @groceries = group.categories.create!(budget: @plan, name: "Groceries")
    @dining = group.categories.create!(budget: @plan, name: "Dining")
    @writer = TransactionWriter.new(@plan)
    @today = Date.current
  end

  def attrs(extra = {})
    { "account_id" => @checking.public_id, "date" => @today.iso8601, "amount" => -25_000 }.merge(extra)
  end

  def activity(category)
    category.month_categories.find_by(month: @today.beginning_of_month)&.activity.to_i
  end

  test "build writes nothing and persist_new applies account and category effects once" do
    transaction = @writer.build(attrs("category_id" => @groceries.public_id))
    assert transaction.new_record?
    assert_equal 0, @checking.reload.balance

    @writer.persist_new!(transaction)
    assert_equal(-25_000, @checking.reload.balance)
    assert_equal(-25_000, activity(@groceries))
  end

  test "update reverses the old effects before applying the new ones" do
    transaction = @writer.persist_new!(@writer.build(attrs("category_id" => @groceries.public_id)))
    Transaction.transaction { @writer.update!(transaction, { "amount" => -10_000, "category_id" => @dining.public_id }, rebuild_subs: true) }

    assert_equal(-10_000, @checking.reload.balance)
    assert_equal 0, activity(@groceries)
    assert_equal(-10_000, activity(@dining))
  end

  test "an invalid update raises, rolls back and leaves balances unchanged" do
    transaction = @writer.persist_new!(@writer.build(attrs("category_id" => @groceries.public_id)))

    error = assert_raises(TransactionWriter::Invalid) do
      Transaction.transaction { @writer.update!(transaction, { "amount" => -1_000, "category_id" => "missing" }, rebuild_subs: true) }
    end
    assert_equal "The category_id is not valid.", error.message
    assert_equal(-25_000, @checking.reload.balance)
    assert_equal(-25_000, activity(@groceries))
  end

  test "destroy reverses the effects and soft deletes the row and its transfer mirror" do
    transaction = @writer.persist_new!(@writer.build(attrs("transfer_account_id" => @savings.public_id)))
    assert_equal 25_000 * -1, @checking.reload.balance
    assert_equal 25_000, @savings.reload.balance

    Transaction.transaction { @writer.destroy!(transaction) }
    assert_equal 0, @checking.reload.balance
    assert_equal 0, @savings.reload.balance
    assert transaction.reload.deleted
    assert transaction.transfer_transaction.deleted
  end

  test "splits must add up to the parent and move only the child categories" do
    error = assert_raises(TransactionWriter::Invalid) do
      @writer.build(attrs("subtransactions" => [ { "amount" => -10_000, "category_id" => @groceries.public_id }, { "amount" => -5_000 } ]))
    end
    assert_equal TransactionWriter::SUB_TOTAL, error.message

    split = @writer.persist_new!(@writer.build(attrs("subtransactions" => [
      { "amount" => -10_000, "category_id" => @groceries.public_id },
      { "amount" => -15_000, "category_id" => @dining.public_id }
    ])))
    assert_equal 2, split.sub_transactions.count
    assert_equal(-25_000, @checking.reload.balance)
    assert_equal(-10_000, activity(@groceries))
    assert_equal(-15_000, activity(@dining))
  end

  test "dates in the future, bad dates and other plans' accounts are rejected" do
    assert_equal TransactionWriter::FUTURE_DATE, assert_raises(TransactionWriter::Invalid) { @writer.build(attrs("date" => (@today + 1).iso8601)) }.message
    assert_equal TransactionWriter::BAD_DATE, assert_raises(TransactionWriter::Invalid) { @writer.build(attrs("date" => "2026-13-45")) }.message

    other_plan = @user.budgets.create!(name: "Other")
    other_account = other_plan.accounts.create!(name: "Theirs", type: "checking")
    assert_equal "The account_id is not valid.", assert_raises(TransactionWriter::Invalid) { @writer.build(attrs("account_id" => other_account.public_id)) }.message
  end
end
