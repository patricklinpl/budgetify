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
        "name" => "Unauthorized",
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

  test "JSON login issues a bearer token accepted by GET /v1/user" do
    post "/v1/session", params: {
      email_address: @user.email_address,
      password: "password"
    }, as: :json

    assert_response :created
    login_response = response.parsed_body
    assert_equal "bearer", login_response.dig("data", "token_type")

    get "/v1/user", headers: authorization_header(login_response.dig("data", "access_token"))

    assert_response :success
    assert_equal @user.public_id, response.parsed_body.dig("data", "user", "id")
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
