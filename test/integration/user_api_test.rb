require "test_helper"

class UserApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @session = @user.sessions.create!
    @access_token = @session.generate_api_token!
  end

  test "GET /v1/user requires a valid bearer token" do
    get "/v1/user"

    assert_response :unauthorized
    assert_equal({
      "error" => {
        "id" => "401",
        "name" => "unauthorized",
        "detail" => "A valid bearer token is required."
      }
    }, response.parsed_body)

    get "/v1/user", headers: authorization_header("invalid")

    assert_response :unauthorized
  end

  test "GET /v1/user returns the authenticated user's UUID in the YNAB envelope" do
    get "/v1/user", headers: authorization_header(@access_token)

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal({ "data" => { "user" => { "id" => @user.public_id } } }, response.parsed_body)
  end

  test "POST /loginUser returns a YNAB-style response and usable session token" do
    post "/loginUser", params: {
      email: @user.email_address,
      password: "password"
    }, as: :json

    assert_response :ok
    session_token = response.parsed_body.fetch("session_token")
    @user.reload

    assert_equal({
      "error" => nil,
      "session_token" => session_token,
      "email_confirmation_required" => false,
      "helpscout_user_hash" => nil,
      "castle_user_jwt" => nil,
      "user_help_access_initial_jwt" => nil,
      "user" => {
        "id" => @user.public_id,
        "username" => nil,
        "email" => @user.email_address,
        "is_subscribed" => false,
        "is_tombstone" => false,
        "trial_expires_on" => nil,
        "sign_in_count" => 1,
        "family_id" => nil,
        "family_role" => nil,
        "annual_subscription_price" => nil,
        "trial_days_remaining" => nil,
        "initial_budget_template" => nil,
        "required_privacy_policy_version" => nil,
        "is_referral_program_available" => false,
        "created_at" => @user.created_at.utc.iso8601(3),
        "confirmed_at" => nil,
        "first_name" => nil,
        "self_reported_source" => nil,
        "initial_intention" => nil
      }
    }, response.parsed_body)
    refute response.parsed_body.key?("budget_version")
    refute response.parsed_body.key?("user_budget")

    get "/v1/user", headers: authorization_header(session_token)

    assert_response :success
    assert_equal @user.public_id, response.parsed_body.dig("data", "user", "id")
  end

  test "POST /loginUser returns the specified 401 for invalid credentials" do
    [
      { email: @user.email_address, password: "wrong-password" },
      { email: "missing@example.com", password: "wrong-password" }
    ].each do |credentials|
      post "/loginUser", params: credentials, as: :json

      assert_response :unauthorized
      assert_equal({
        "error" => {
          "id" => "user_not_found",
          "message" => "Unauthorized: unknown username and/or password"
        }
      }, response.parsed_body)
    end
  end

  test "DELETE /v1/session revokes the bearer token" do
    delete "/v1/session", headers: authorization_header(@access_token)

    assert_response :no_content

    get "/v1/user", headers: authorization_header(@access_token)

    assert_response :unauthorized
  end

  private

  def authorization_header(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
