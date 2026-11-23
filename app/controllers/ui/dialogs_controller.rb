module Ui
  # Component preview for dialog, menu and confirmation primitives (#71).
  # Registered in routes only outside production.
  class DialogsController < ApplicationController
    allow_unauthenticated_access
    layout "ui_preview"

    def show
      @theme = params[:theme] == "dark" ? "dark" : "light"
    end
  end
end
