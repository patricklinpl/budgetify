require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get users_sign_in_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to users_sign_in_path
    assert_nil cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to users_sign_in_path
    assert_empty cookies[:session_id]
  end

  # The production limit stays: the 11th sign-in attempt in 3 minutes is
  # refused, even with correct credentials. Isolated from other tests by the
  # cache clear around it (the counter lives in the process cache).
  test "create is rate limited to 10 attempts per 3 minutes" do
    Rails.cache.clear
    10.times do
      post session_path, params: { email_address: @user.email_address, password: "wrong" }
      assert_redirected_to users_sign_in_path
      assert_nil flash[:alert].to_s[/Try again later/]
    end

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to users_sign_in_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil cookies[:session_id]
  ensure
    Rails.cache.clear
  end
end
