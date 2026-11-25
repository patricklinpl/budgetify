require "test_helper"

# [engineering] The payee lookup in TransactionWriter#build and the insert in
# persist_new! must be one write transaction on the API create paths. A payee
# write on a second connection (a combine or delete commit) must not get in
# between, or the new row would point at a payee that is already removed.
# Real second connection, no stubs of the database: at the moment persist_new!
# starts, a second thread tries to soft-delete the payee. When the create is one
# transaction, SQLite refuses that write (the request holds the write lock);
# otherwise it commits and the row ends up on a deleted payee.
class TransactionsApiPayeeWindowTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  module SecondConnectionWrite
    cattr_accessor :target_payee_id, :outcomes

    def persist_new!(transaction)
      if SecondConnectionWrite.target_payee_id
        id = SecondConnectionWrite.target_payee_id
        SecondConnectionWrite.target_payee_id = nil
        SecondConnectionWrite.outcomes << Thread.new do
          pool = ActiveRecord::Base.connection_pool
          connection = pool.checkout
          begin
            connection.execute("PRAGMA busy_timeout = 100")
            connection.transaction { connection.execute("UPDATE payees SET deleted = 1 WHERE id = #{id.to_i}") }
            :committed
          rescue ActiveRecord::StatementInvalid, ActiveRecord::LockWaitTimeout => e
            e.cause&.class&.name || e.class.name
          ensure
            # Short timeout was set on this connection only: drop it, never return it to the pool.
            pool.remove(connection)
            connection.disconnect!
          end
        end.value
      end
      super
    end
  end

  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "window#{SecureRandom.hex(4)}@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    @plan = @user.budgets.create!(name: "Window")
    @account = @plan.accounts.create!(name: "Checking", type: "checking")
    @payee = @plan.payees.create!(name: "Window Payee")
    SecondConnectionWrite.outcomes = []
    TransactionWriter.prepend(SecondConnectionWrite) unless TransactionWriter < SecondConnectionWrite
  end

  teardown do
    SecondConnectionWrite.target_payee_id = nil
    @user.destroy
  end

  def payload(extra = {})
    { account_id: @account.public_id, date: Date.current.iso8601, amount: -1_000, payee_id: @payee.public_id }.merge(extra)
  end

  def assert_window_closed
    assert_equal [ "SQLite3::BusyException" ], SecondConnectionWrite.outcomes, "the second connection must not commit between the payee lookup and the insert"
    assert_not Payee.find(@payee.id).deleted
    assert_equal @payee.id, Transaction.order(:id).last.payee_id
  end

  test "single create holds the write lock from the payee lookup to the insert" do
    SecondConnectionWrite.target_payee_id = @payee.id
    post "/v1/plans/#{@plan.public_id}/transactions", params: { transaction: payload }, as: :json, headers: { "Authorization" => "Bearer #{@token}" }

    assert_response :created
    assert_window_closed
  end

  test "bulk create holds the write lock from the payee lookup to the insert for each entry" do
    SecondConnectionWrite.target_payee_id = @payee.id
    post "/v1/plans/#{@plan.public_id}/transactions", params: { transactions: [ payload ] }, as: :json, headers: { "Authorization" => "Bearer #{@token}" }

    assert_response :created
    assert_window_closed
  end

  # Actual API outcome under contention: a competing writer that holds the write
  # lock briefly makes the request wait (database timeout is 5 s), not fail.
  test "single create waits for a competing writer and still succeeds" do
    ready = Queue.new
    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Payee.where(id: @payee.id).update_all(name: "Renamed")
          ready << true
          sleep 0.4
        end
      end
    end
    ready.pop
    post "/v1/plans/#{@plan.public_id}/transactions", params: { transaction: payload }, as: :json, headers: { "Authorization" => "Bearer #{@token}" }
    other.join

    assert_response :created
    assert_equal @payee.id, Transaction.order(:id).last.payee_id
  end

  test "single create on a payee deleted before the request is a client error, not a server error" do
    Payee.where(id: @payee.id).update_all(deleted: true)
    post "/v1/plans/#{@plan.public_id}/transactions", params: { transaction: payload }, as: :json, headers: { "Authorization" => "Bearer #{@token}" }

    assert_includes 400..499, response.status
    assert_equal 0, Transaction.where(payee_id: @payee.id).count
  end
end
