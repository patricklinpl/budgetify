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
  get "v1/plans", to: "api/v1/plans#index", as: :api_v1_plans, defaults: { format: :json }
  get "v1/plans/:plan_id", to: "api/v1/plans#show", as: :api_v1_plan, defaults: { format: :json }
  get "v1/plans/:plan_id/settings", to: "api/v1/plan_settings#show", as: :api_v1_plan_settings, defaults: { format: :json }
  get "v1/plans/:plan_id/accounts", to: "api/v1/accounts#index", defaults: { format: :json }
  post "v1/plans/:plan_id/accounts", to: "api/v1/accounts#create", defaults: { format: :json }
  get "v1/plans/:plan_id/accounts/:account_id", to: "api/v1/accounts#show", defaults: { format: :json }
  get "v1/plans/:plan_id/categories", to: "api/v1/categories#index", defaults: { format: :json }
  post "v1/plans/:plan_id/categories", to: "api/v1/categories#create", defaults: { format: :json }
  get "v1/plans/:plan_id/categories/:category_id", to: "api/v1/categories#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/categories/:category_id", to: "api/v1/categories#update", defaults: { format: :json }
  post "v1/plans/:plan_id/category_groups", to: "api/v1/category_groups#create", defaults: { format: :json }
  patch "v1/plans/:plan_id/category_groups/:category_group_id", to: "api/v1/category_groups#update", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month/categories/:category_id", to: "api/v1/month_categories#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/months/:month/categories/:category_id", to: "api/v1/month_categories#update", defaults: { format: :json }

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
