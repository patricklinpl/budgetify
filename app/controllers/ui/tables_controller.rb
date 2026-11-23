module Ui
  # Component preview for the table primitives (#69). Registered in routes only
  # outside production; it shows each primitive and state in both themes.
  class TablesController < ApplicationController
    allow_unauthenticated_access
    layout "ui_preview"

    def show
      @theme = params[:theme] == "dark" ? "dark" : "light"
    end
  end
end
