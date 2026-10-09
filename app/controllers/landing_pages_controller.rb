class LandingPagesController < ApplicationController
  allow_unauthenticated_access

  helper_method :app_entry_url

  def show
  end

  private

  def app_entry_url
    app_root_url(host: app_host, port: request.port, protocol: request.protocol)
  end

  def app_host
    return "app.localhost" if %w[localhost 127.0.0.1].include?(request.host)

    "app.#{request.host.delete_prefix("www.")}"
  end
end
