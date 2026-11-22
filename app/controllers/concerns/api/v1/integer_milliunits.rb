module Api
  module V1
    # Validate JSON money values before ActiveRecord's integer casting or
    # any writes. The no-float rule is issue #25's explicit contract; the
    # pinned schemas specify integer/int64, not a coercion/error policy.
    module IntegerMilliunits
      extend ActiveSupport::Concern

      # Values are nullable only where the input schema permits null.
      INPUT_FIELDS = {
        "accounts" => { "account" => { "balance" => false } },
        "transactions" => { "transaction" => { "amount" => false }, "transactions" => { "amount" => false } },
        "scheduled_transactions" => { "scheduled_transaction" => { "amount" => false } },
        "month_categories" => { "category" => { "budgeted" => false } },
        "categories" => { "category" => { "goal_target" => true } }
      }.freeze
      INT64_RANGE = (-(2**63))..((2**63) - 1)

      included do
        before_action :validate_integer_milliunit_inputs
      end

      private
        def validate_integer_milliunit_inputs
          return unless request.post? || request.put? || request.patch?

          INPUT_FIELDS.fetch(controller_name, {}).each do |wrapper, fields|
            Array.wrap(params[wrapper]).each do |attributes|
              next unless attributes.respond_to?(:key?)

              fields.each do |field, nullable|
                next unless attributes.key?(field)
                next if nullable && attributes[field].nil?
                return invalid_milliunits("#{wrapper}.#{field}") unless integer_milliunits?(attributes[field])
              end
              # Split parts require amount even when the parent amount
              # is omitted. Validate every part before bulk writes begin,
              # so fractional values cannot pass a truncating sum check.
              Array.wrap(attributes["subtransactions"]).each do |part|
                next unless part.respond_to?(:key?)
                return invalid_milliunits("#{wrapper}.subtransactions.amount") unless integer_milliunits?(part["amount"])
              end
            end
          end
        end

        def integer_milliunits?(value)
          value.is_a?(Integer) && INT64_RANGE.cover?(value)
        end

        def invalid_milliunits(field)
          render_api_error(:bad_request, "#{field} must be integer milliunits in the signed 64-bit range.", id: "400", name: "bad_request")
        end
    end
  end
end
