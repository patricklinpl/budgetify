Rails.application.routes.draw do
  resource :session, only: %i[ create destroy ]
  resources :passwords, param: :token
  post "loginUser", to: "api/v1/sessions#create", as: :login_user, defaults: { format: :json }
  delete "v1/session", to: "api/v1/sessions#destroy", defaults: { format: :json }
  get "users/sign_in", to: "sessions#new", as: :users_sign_in

  constraints(lambda { |request| request.host.start_with?("app.") }) do
    root "app_homes#show", as: :app_root
  end
  root "landing_pages#show"
  namespace :users do
    resources :budgets, only: %i[index show], param: :public_id
  end
  get "api/v1/catalog", to: "api/v1/catalogs#index", as: :api_v1_catalog, defaults: { format: :json }
  get "v1/user", to: "api/v1/users#show", as: :api_v1_user, defaults: { format: :json }
  get "v1/plans/:plan_id/accounts", to: "api/v1/accounts#index", defaults: { format: :json }
  post "v1/plans/:plan_id/accounts", to: "api/v1/accounts#create", defaults: { format: :json }
  get "v1/plans/:plan_id/accounts/:account_id", to: "api/v1/accounts#show", defaults: { format: :json }

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to check the state of their deployed instances.

  # Defines the root path route ("/")
  # root "posts#index"
end
