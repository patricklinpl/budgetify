module Ui
  # Component preview for the form primitives (#70). Registered in routes only
  # outside production.
  class FormsController < ApplicationController
    allow_unauthenticated_access
    layout "ui_preview"

    def show
      @theme = params[:theme] == "dark" ? "dark" : "light"
      @payees = [ "Corner Market", "Home Supply", "Landlord", "Old Gym (hidden)" ]
    end
  end
end
