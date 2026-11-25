Rails.application.routes.draw do
  get "v1/plans/:plan_id/scheduled_transactions", to: "api/v1/scheduled_transactions#index", defaults: { format: :json }

  post "v1/plans/:plan_id/scheduled_transactions", to: "api/v1/scheduled_transactions#create", defaults: { format: :json }

  get "v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id", to: "api/v1/scheduled_transactions#show", defaults: { format: :json }

  put "v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id", to: "api/v1/scheduled_transactions#update", defaults: { format: :json }

  delete "v1/plans/:plan_id/scheduled_transactions/:scheduled_transaction_id", to: "api/v1/scheduled_transactions#destroy", defaults: { format: :json }


  resource :session, only: %i[ create destroy ]
  resources :passwords, param: :token
  post "loginUser", to: "api/v1/sessions#create", as: :login_user, defaults: { format: :json }
  delete "v1/session", to: "api/v1/sessions#destroy", defaults: { format: :json }
  get "users/sign_in", to: "sessions#new", as: :users_sign_in

  # Component preview for dialog primitives (#71); not routed in production.
  get "ui/dialogs", to: "ui/dialogs#show", as: :ui_dialogs unless Rails.env.production?

  # Component preview for UI primitives (#69); not routed in production.
  get "ui/tables", to: "ui/tables#show", as: :ui_tables unless Rails.env.production?
  # Component preview for form primitives (#70); not routed in production.
  get "ui/forms", to: "ui/forms#show", as: :ui_forms unless Rails.env.production?

  constraints(lambda { |request| request.host.start_with?("app.") }) do
    root "app_homes#show", as: :app_root
  end
  root "landing_pages#show"
  namespace :users do
    resources :budgets, only: %i[index show create update], param: :public_id do
      post "undo", to: "undo#undo", as: :undo
      post "redo", to: "undo#redo", as: :redo
      member do
        get :settings
        post :fresh_start
        get :moves
      end
      resource :reflect, only: :show, controller: "reflect"
      resources :categories, only: %i[edit update destroy], param: :public_id do
        member do
          patch :assign
          get :cover
          get :target
          patch "target", action: :target_update, as: :target_update
          delete "target", action: :target_destroy, as: :target_destroy
          post "target/assign", action: :target_assign, as: :target_assign
          post "cover", action: :cover_create, as: :cover_confirm
        end
      end
      resources :accounts, only: %i[new create edit update destroy], param: :public_id do
        member do
          post :close
          post :reopen
          post :adjust
        end
        resource :reconciliation, only: %i[show create]
        resources :transactions, only: %i[index new create edit update destroy], param: :public_id do
          resource :split, only: %i[edit update], controller: "transaction_splits"
        end
      end
    end
  end
  get "api/v1/catalog", to: "api/v1/catalogs#index", as: :api_v1_catalog, defaults: { format: :json }
  get "v1/user", to: "api/v1/users#show", as: :api_v1_user, defaults: { format: :json }
  get "v1/plans", to: "api/v1/plans#index", as: :api_v1_plans, defaults: { format: :json }
  post "v1/plans", to: "api/v1/plans#create", defaults: { format: :json }
  get "v1/plans/:plan_id", to: "api/v1/plans#show", as: :api_v1_plan, defaults: { format: :json }
  patch "v1/plans/:plan_id", to: "api/v1/plans#update", defaults: { format: :json }
  post "v1/plans/:plan_id/fresh_start", to: "api/v1/plans#fresh_start", defaults: { format: :json }
  get "v1/plans/:plan_id/settings", to: "api/v1/plan_settings#show", as: :api_v1_plan_settings, defaults: { format: :json }
  patch "v1/plans/:plan_id/settings", to: "api/v1/plan_settings#update", defaults: { format: :json }
  get "v1/plans/:plan_id/accounts", to: "api/v1/accounts#index", defaults: { format: :json }
  post "v1/plans/:plan_id/accounts", to: "api/v1/accounts#create", defaults: { format: :json }
  get "v1/plans/:plan_id/accounts/:account_id", to: "api/v1/accounts#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/accounts/:account_id", to: "api/v1/accounts#update", defaults: { format: :json }
  delete "v1/plans/:plan_id/accounts/:account_id", to: "api/v1/accounts#destroy", defaults: { format: :json }
  get "v1/plans/:plan_id/categories", to: "api/v1/categories#index", defaults: { format: :json }
  post "v1/plans/:plan_id/categories", to: "api/v1/categories#create", defaults: { format: :json }
  get "v1/plans/:plan_id/categories/:category_id", to: "api/v1/categories#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/categories/:category_id", to: "api/v1/categories#update", defaults: { format: :json }
  delete "v1/plans/:plan_id/categories/:category_id", to: "api/v1/categories#destroy", defaults: { format: :json }
  post "v1/plans/:plan_id/category_groups", to: "api/v1/category_groups#create", defaults: { format: :json }
  patch "v1/plans/:plan_id/category_groups/:category_group_id", to: "api/v1/category_groups#update", defaults: { format: :json }
  delete "v1/plans/:plan_id/category_groups/:category_group_id", to: "api/v1/category_groups#destroy", defaults: { format: :json }
  get "v1/plans/:plan_id/months", to: "api/v1/months#index", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month", to: "api/v1/months#show", defaults: { format: :json }
  get "v1/plans/:plan_id/transactions", to: "api/v1/transactions#index", defaults: { format: :json }
  post "v1/plans/:plan_id/transactions", to: "api/v1/transactions#create", defaults: { format: :json }
  patch "v1/plans/:plan_id/transactions", to: "api/v1/transactions#update_bulk", defaults: { format: :json }
  post "v1/plans/:plan_id/transactions/import", to: "api/v1/transactions#import", defaults: { format: :json }
  get "v1/plans/:plan_id/transactions/:transaction_id", to: "api/v1/transactions#show", defaults: { format: :json }
  put "v1/plans/:plan_id/transactions/:transaction_id", to: "api/v1/transactions#update", defaults: { format: :json }
  delete "v1/plans/:plan_id/transactions/:transaction_id", to: "api/v1/transactions#destroy", defaults: { format: :json }
  get "v1/plans/:plan_id/accounts/:account_id/transactions", to: "api/v1/transactions#for_account", defaults: { format: :json }
  get "v1/plans/:plan_id/categories/:category_id/transactions", to: "api/v1/transactions#for_category", defaults: { format: :json }
  get "v1/plans/:plan_id/payees/:payee_id/transactions", to: "api/v1/transactions#for_payee", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month/transactions", to: "api/v1/transactions#for_month", defaults: { format: :json }
  get "v1/plans/:plan_id/money_movements", to: "api/v1/money_movements#index", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month/money_movements", to: "api/v1/money_movements#for_month", defaults: { format: :json }
  get "v1/plans/:plan_id/money_movement_groups", to: "api/v1/money_movement_groups#index", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month/money_movement_groups", to: "api/v1/money_movement_groups#for_month", defaults: { format: :json }
  get "v1/plans/:plan_id/months/:month/categories/:category_id", to: "api/v1/month_categories#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/months/:month/categories/:category_id", to: "api/v1/month_categories#update", defaults: { format: :json }
  get "v1/plans/:plan_id/payees", to: "api/v1/payees#index", defaults: { format: :json }
  post "v1/plans/:plan_id/payees", to: "api/v1/payees#create", defaults: { format: :json }
  get "v1/plans/:plan_id/payees/:payee_id", to: "api/v1/payees#show", defaults: { format: :json }
  patch "v1/plans/:plan_id/payees/:payee_id", to: "api/v1/payees#update", defaults: { format: :json }
  get "v1/plans/:plan_id/payee_locations", to: "api/v1/payee_locations#index", defaults: { format: :json }
  get "v1/plans/:plan_id/payee_locations/:payee_location_id", to: "api/v1/payee_locations#show", defaults: { format: :json }
  get "v1/plans/:plan_id/payees/:payee_id/payee_locations", to: "api/v1/payee_locations#for_payee", defaults: { format: :json }

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
