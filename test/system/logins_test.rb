require "application_system_test_case"

class LoginsTest < ApplicationSystemTestCase
  test "invalid credentials show the friendly sign-in message" do
    visit users_sign_in_path

    fill_in "Email", with: "missing@example.test"
    fill_in "Password", with: "incorrect-password"
    click_button "Log in"

    assert_text "We weren't able to log you in. Please check that your email and password are correct."
  end
end
