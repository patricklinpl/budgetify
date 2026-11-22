require "test_helper"

# Contract checks against YNAB's official OpenAPI spec (v1.88.0), vendored
# verbatim from the public ynab/ynab-sdk-js repo (open_api_spec.yaml) at
# test/fixtures/files/ynab_open_api_spec_v1.88.0.yaml.
#
# These checks mechanically compare the foundations conventions (success
# envelope, error envelope, uuid ids, delta-request parameters, milliunit
# amounts) with the spec's schemas. They are a development aid; the formal
# parity verdict belongs to the independent verifier.
class YnabContractTest < ActionDispatch::IntegrationTest
  SPEC_PATH = Rails.root.join("test/fixtures/files/ynab_open_api_spec_v1.88.0.yaml")

  setup { Rails.cache.clear }
  teardown { Rails.cache.clear }

  def spec
    @spec ||= YAML.load_file(SPEC_PATH, aliases: true)
  end

  test "vendored spec is the pinned YNAB v1.88.0 spec" do
    assert_equal "1.88.0", spec.dig("info", "version")
  end

  test "the error envelope conforms to the spec's ErrorResponse schema" do
    get "/v1/user" # unauthenticated

    assert_response :unauthorized
    assert_json_conforms_to_schema response.parsed_body, "ErrorResponse"
  end

  test "GET /v1/user conforms to the spec's UserResponse schema" do
    user = User.create!(email_address: "contract@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!

    get "/v1/user", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "UserResponse"
  end

  test "GET /v1/plans conforms to the spec's PlanSummaryResponse schema" do
    user = User.create!(email_address: "contract-plans@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    user.budgets.create!(name: "Everyday")

    get "/v1/plans", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PlanSummaryResponse"
  end

  test "GET /v1/plans/:plan_id conforms to the spec's PlanDetailResponse schema" do
    user = User.create!(email_address: "contract-plan@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")

    get "/v1/plans/#{plan.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PlanDetailResponse"
  end

  test "GET /v1/plans/:plan_id/settings conforms to the spec's PlanSettingsResponse schema" do
    user = User.create!(email_address: "contract-settings@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")

    get "/v1/plans/#{plan.public_id}/settings", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PlanSettingsResponse"
  end

  test "the spec keeps the delta-request contract the foundations implement" do
    # Locks the convention target: plan-scoped list endpoints take
    # last_knowledge_of_server and their responses carry server_knowledge.
    accounts = spec.dig("paths", "/plans/{plan_id}/accounts", "get")
    param_names = accounts.fetch("parameters").map { |parameter| parameter.fetch("name") }
    assert_includes param_names, "last_knowledge_of_server"

    accounts_response = resolve_schema(spec.dig("components", "schemas", "AccountsResponse"))
    assert accounts_response.dig("properties", "data", "properties", "server_knowledge"),
      "spec list responses must carry server_knowledge"
  end

  test "the spec keeps the milliunit money convention the foundations implement" do
    account = resolve_schema(spec.dig("components", "schemas", "Account"))
    assert_equal "integer", account.dig("properties", "balance", "type")
    assert_equal "int64", account.dig("properties", "balance", "format")
  end

  test "GET /v1/plans/:plan_id/categories conforms to the spec's CategoriesResponse schema" do
    user = User.create!(email_address: "contract-categories@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")
    group.categories.create!(budget: plan, name: "Groceries")

    get "/v1/plans/#{plan.public_id}/categories", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "CategoriesResponse"
  end

  test "GET /v1/plans/:plan_id/categories/:category_id conforms to the spec's CategoryResponse schema" do
    user = User.create!(email_address: "contract-category@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")
    category = group.categories.create!(budget: plan, name: "Groceries")

    get "/v1/plans/#{plan.public_id}/categories/#{category.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "CategoryResponse"
  end

  test "GET /v1/plans/:plan_id/months/:month/categories/:category_id conforms to the spec's CategoryResponse schema" do
    user = User.create!(email_address: "contract-month-category@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")
    category = group.categories.create!(budget: plan, name: "Groceries")
    month = Date.current.beginning_of_month

    get "/v1/plans/#{plan.public_id}/months/#{month.iso8601}/categories/#{category.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "CategoryResponse"
  end

  test "POST /v1/plans/:plan_id/categories conforms to the spec's SaveCategoryResponse schema" do
    user = User.create!(email_address: "contract-save-category@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")

    post "/v1/plans/#{plan.public_id}/categories",
      params: { category: { category_group_id: group.public_id, name: "Groceries", goal_target: 400_000, goal_frequency: "monthly" } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_json_conforms_to_schema response.parsed_body, "SaveCategoryResponse"
  end

  test "PATCH /v1/plans/:plan_id/categories/:category_id conforms to the spec's SaveCategoryResponse schema" do
    user = User.create!(email_address: "contract-patch-category@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")
    category = group.categories.create!(budget: plan, name: "Groceries")

    patch "/v1/plans/#{plan.public_id}/categories/#{category.public_id}",
      params: { category: { name: "Food" } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "SaveCategoryResponse"
  end

  test "PATCH /v1/plans/:plan_id/months/:month/categories/:category_id conforms to the spec's SaveCategoryResponse schema" do
    user = User.create!(email_address: "contract-patch-month-category@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    group = plan.category_groups.create!(name: "Everyday Expenses")
    category = group.categories.create!(budget: plan, name: "Groceries")

    patch "/v1/plans/#{plan.public_id}/months/current/categories/#{category.public_id}",
      params: { category: { budgeted: 350_000 } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "SaveCategoryResponse"
  end

  test "POST /v1/plans/:plan_id/category_groups conforms to the spec's SaveCategoryGroupResponse schema" do
    user = User.create!(email_address: "contract-category-group@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")

    post "/v1/plans/#{plan.public_id}/category_groups",
      params: { category_group: { name: "Giving" } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_json_conforms_to_schema response.parsed_body, "SaveCategoryGroupResponse"
  end

  test "GET /v1/plans/:plan_id/payees conforms to the spec's PayeesResponse schema" do
    user = User.create!(email_address: "contract-payees@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    plan.payees.create!(name: "Grocery Store")

    get "/v1/plans/#{plan.public_id}/payees", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PayeesResponse"
  end

  test "POST /v1/plans/:plan_id/payees conforms to the spec's SavePayeeResponse schema" do
    user = User.create!(email_address: "contract-save-payee@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")

    post "/v1/plans/#{plan.public_id}/payees",
      params: { payee: { name: "Coffee Shop" } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_json_conforms_to_schema response.parsed_body, "SavePayeeResponse"
  end

  test "GET /v1/plans/:plan_id/payees/:payee_id conforms to the spec's PayeeResponse schema" do
    user = User.create!(email_address: "contract-payee@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    payee = plan.payees.create!(name: "Grocery Store")

    get "/v1/plans/#{plan.public_id}/payees/#{payee.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PayeeResponse"
  end

  test "GET /v1/plans/:plan_id/payee_locations conforms to the spec's PayeeLocationsResponse schema" do
    user = User.create!(email_address: "contract-payee-locations@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    payee = plan.payees.create!(name: "Coffee Shop")
    payee.payee_locations.create!(latitude: "49.2827", longitude: "-123.1207")

    get "/v1/plans/#{plan.public_id}/payee_locations", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PayeeLocationsResponse"
  end

  test "GET /v1/plans/:plan_id/payee_locations/:payee_location_id conforms to the spec's PayeeLocationResponse schema" do
    user = User.create!(email_address: "contract-payee-location@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    payee = plan.payees.create!(name: "Coffee Shop")
    location = payee.payee_locations.create!(latitude: "49.2827", longitude: "-123.1207")

    get "/v1/plans/#{plan.public_id}/payee_locations/#{location.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "PayeeLocationResponse"
  end

  private
    def resolve_schema(schema)
      seen = []
      while schema.is_a?(Hash) && schema.key?("$ref")
        ref = schema.fetch("$ref")
        raise "unsupported $ref: #{ref}" unless ref.start_with?("#/components/schemas/")
        raise "recursive $ref: #{ref}" if seen.include?(ref)

        seen << ref
        schema = spec.dig("components", "schemas", ref.delete_prefix("#/components/schemas/"))
        raise "missing schema: #{ref}" if schema.nil?
      end

      return schema unless schema.is_a?(Hash) && schema.key?("allOf")

      # Flatten allOf composition (e.g. Account = AccountBase + inline
      # extension) so property lookups see the merged property set.
      merged = schema.reject { |key, _| key == "allOf" }
      schema.fetch("allOf").each do |subschema|
        resolved = resolve_schema(subschema)
        merged["properties"] = (merged["properties"] || {}).merge(resolved["properties"] || {})
        merged["required"] = (merged["required"] || []) | (resolved["required"] || [])
        resolved.each do |key, value|
          merged[key] = value unless %w[properties required].include?(key) || merged.key?(key)
        end
      end
      merged
    end

    def assert_json_conforms_to_schema(json, schema_name)
      schema = resolve_schema(spec.dig("components", "schemas", schema_name))
      assert_schema_node(json, schema, schema_name)
    end

    def assert_schema_node(json, schema, path)
      schema = resolve_schema(schema)
      if schema.key?("allOf")
        schema.fetch("allOf").each { |subschema| assert_schema_node(json, subschema, path) }
        return
      end

      types = Array(schema["type"] || (schema.key?("properties") ? "object" : nil))
      if json.nil?
        assert types.include?("null") || schema["nullable"],
          "expected #{path} to be present (schema types: #{types.inspect})"
        return
      end

      if types.include?("object")
        assert json.is_a?(Hash), "expected #{path} to be an object, got #{json.class}"
        Array(schema["required"]).each do |key|
          assert json.key?(key), "expected #{path} to include #{key.inspect}"
        end
        schema.fetch("properties", {}).each do |key, subschema|
          assert_schema_node(json[key], subschema, "#{path}.#{key}") if json.key?(key)
        end
      elsif types.include?("array")
        assert json.is_a?(Array), "expected #{path} to be an Array, got #{json.class}"
        json.each_with_index { |item, index| assert_schema_node(item, schema.fetch("items"), "#{path}[#{index}]") }
      elsif types.include?("integer")
        assert json.is_a?(Integer), "expected #{path} to be an Integer, got #{json.inspect}"
      elsif types.include?("number")
        assert json.is_a?(Numeric), "expected #{path} to be Numeric, got #{json.inspect}"
      elsif types.include?("boolean")
        assert_includes [ true, false ], json, "expected #{path} to be boolean, got #{json.inspect}"
      elsif types.include?("string")
        assert json.is_a?(String), "expected #{path} to be a String, got #{json.inspect}"
        if schema["format"] == "uuid"
          assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, json,
            "expected #{path} to be a uuid, got #{json.inspect}")
        end
      end
    end
  test "GET /v1/plans/:plan_id/accounts conforms to the spec's AccountsResponse schema" do
    user = User.create!(email_address: "contract-accounts@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    plan.accounts.create!(name: "Checking", type: "checking", balance: 123450)

    get "/v1/plans/#{plan.public_id}/accounts", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "AccountsResponse"
  end

  test "GET /v1/plans/:plan_id/accounts/:account_id conforms to the spec's AccountResponse schema" do
    user = User.create!(email_address: "contract-account@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")
    account = plan.accounts.create!(name: "Checking", type: "checking", balance: 0)

    get "/v1/plans/#{plan.public_id}/accounts/#{account.public_id}", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :ok
    assert_json_conforms_to_schema response.parsed_body, "AccountResponse"
  end

  test "POST /v1/plans/:plan_id/accounts conforms to the spec's AccountResponse schema" do
    user = User.create!(email_address: "contract-account-create@example.com", password: "password123")
    token = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test").generate_api_token!
    plan = user.budgets.create!(name: "Everyday")

    post "/v1/plans/#{plan.public_id}/accounts",
      params: { account: { name: "Checking", type: "checking", balance: 123450 } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :created
    assert_json_conforms_to_schema response.parsed_body, "AccountResponse"
  end
end
