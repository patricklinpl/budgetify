require "test_helper"

# Request-level checks for the foundations conventions (issue #25):
# bearer auth, envelopes, "last-used" plan resolution, delta requests with
# tombstones, and per-token rate limiting.
#
# The conventions ship as shared concerns; the real plan routes land with
# the resource issues (#27+). These tests exercise the concerns through a
# minimal probe controller on temporary routes.
class ApiV1FoundationsTest < ActionDispatch::IntegrationTest
  class ProbePlansController < Api::V1::BaseController
    before_action :authenticate_bearer_session!
    before_action :set_plan, only: :show

    def index
      plans = delta_scope(Current.user.budgets).order(:knowledge).map do |plan|
        { id: plan.public_id, name: plan.name, deleted: plan.deleted }
      end
      render_data({ plans: plans }, server_knowledge: current_server_knowledge)
    end

    def show
      render_data({ plan: { id: plan.public_id, name: plan.name } })
    end
  end

  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "foundations@example.com", password: "password123")
    @token = @user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
  end

  teardown do
    Rails.cache.clear
  end

  test "unauthenticated requests get a 401 in the error envelope" do
    get "/v1/user"

    assert_response :unauthorized
    error = response.parsed_body.fetch("error")
    assert_equal "401", error.fetch("id")
    assert_equal "not_authorized", error.fetch("name")
    assert error.fetch("detail").present?
  end

  test "last-used resolves the most recently used plan" do
    with_probe_routes do
      first = @user.budgets.create!(name: "First")
      second = @user.budgets.create!(name: "Second")

      get "/v1/plans/last-used", headers: auth_headers
      assert_response :ok
      assert_equal second.public_id, response.parsed_body.dig("data", "plan", "id")

      get "/v1/plans/#{first.public_id}", headers: auth_headers
      assert_response :ok

      get "/v1/plans/last-used", headers: auth_headers
      assert_response :ok
      assert_equal first.public_id, response.parsed_body.dig("data", "plan", "id")
    end
  end

  test "unknown and deleted plan ids get a 404 in the error envelope" do
    with_probe_routes do
      plan = @user.budgets.create!(name: "Gone")

      get "/v1/plans/does-not-exist", headers: auth_headers
      assert_response :not_found
      assert_equal "404.2", response.parsed_body.dig("error", "id")
      assert_equal "resource_not_found", response.parsed_body.dig("error", "name")

      plan.update!(deleted: true)
      get "/v1/plans/#{plan.public_id}", headers: auth_headers
      assert_response :not_found
    end
  end

  test "delta requests return changes since last_knowledge_of_server, including tombstones" do
    with_probe_routes do
      first = @user.budgets.create!(name: "First")
      first_knowledge = first.reload.knowledge
      second = @user.budgets.create!(name: "Second")
      initial_knowledge = @user.reload.server_knowledge

      get "/v1/plans", headers: auth_headers
      assert_response :ok
      body = response.parsed_body.fetch("data")
      assert_equal [ first.public_id, second.public_id ], body.fetch("plans").map { |plan| plan.fetch("id") }
      assert_equal initial_knowledge, body.fetch("server_knowledge")

      get "/v1/plans", params: { last_knowledge_of_server: first_knowledge }, headers: auth_headers
      plans = response.parsed_body.fetch("data").fetch("plans")
      assert_equal [ second.public_id ], plans.map { |plan| plan.fetch("id") }

      first.update!(deleted: true)
      get "/v1/plans", params: { last_knowledge_of_server: initial_knowledge }, headers: auth_headers
      plans = response.parsed_body.fetch("data").fetch("plans")
      assert_equal [ first.public_id ], plans.map { |plan| plan.fetch("id") }
      assert_equal true, plans.first.fetch("deleted")

      get "/v1/plans", headers: auth_headers
      plans = response.parsed_body.fetch("data").fetch("plans")
      assert_equal [ second.public_id ], plans.map { |plan| plan.fetch("id") }
    end
  end

  test "requests beyond 200 per hour per token get a 429 in the error envelope" do
    200.times { get "/v1/user", headers: auth_headers }
    assert_response :ok

    get "/v1/user", headers: auth_headers
    assert_response :too_many_requests
    error = response.parsed_body.fetch("error")
    assert_equal "429", error.fetch("id")
    assert_equal "too_many_requests", error.fetch("name")
  end

  private
    def auth_headers
      { "Authorization" => "Bearer #{@token}" }
    end

    def with_probe_routes
      with_routing do |set|
        set.draw do
          scope defaults: { format: :json } do
            get "/v1/plans", to: "api_v1_foundations_test/probe_plans#index"
            get "/v1/plans/:plan_id", to: "api_v1_foundations_test/probe_plans#show"
          end
        end
        yield
      end
    end
end
