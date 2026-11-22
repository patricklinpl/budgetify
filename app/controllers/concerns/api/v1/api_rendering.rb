module Api
  module V1
    # YNAB v1 response conventions (OpenAPI spec v1.88.0).
    #
    # Success envelope (spec: *Response schemas):
    #   { "data": { ... } } with "server_knowledge" on list reads.
    # Error envelope (spec: ErrorResponse / ErrorDetail schemas):
    #   { "error": { "id": "<status>", "name": "<short_name>", "detail": "<message>" } }
    module ApiRendering
      extend ActiveSupport::Concern

      private
        # Renders the YNAB success envelope: { "data": { ... } }. List reads
        # pass server_knowledge (spec: *Response server_knowledge field).
        def render_data(data, server_knowledge: nil, status: :ok)
          data[:server_knowledge] = server_knowledge unless server_knowledge.nil?
          render json: { data: data }, status: status
        end

        # Renders the YNAB error envelope (spec: ErrorDetail schema):
        # { "error": { "id", "name", "detail" } } where "id" is the HTTP
        # status and "name" its snake_case short name.
        def render_api_error(status, detail, id: nil)
          status_code = Rack::Utils.status_code(status)
          render json: {
            error: {
              id: id.presence || status_code.to_s,
              name: Rack::Utils::HTTP_STATUS_CODES.fetch(status_code).downcase.tr(" ", "_"),
              detail: detail
            }
          }, status: status
        end
    end
  end
end
