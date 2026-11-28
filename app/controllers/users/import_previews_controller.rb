module Users
  # Preview of a CSV import into one account. It reads the chosen file, runs it
  # through CsvImport and shows every row with its status and reason. It writes
  # nothing: there is no confirm step yet, and no transaction is created.
  # Every lookup is scoped to the current user's plan; other ids are a 404.
  class ImportPreviewsController < ApplicationController
    layout "app_shell"

    before_action :set_budget
    before_action :set_account

    def create
      @settings = {
        date_format: CsvImport::DATE_FORMATS.key?(params[:date_format].to_s.to_sym) ? params[:date_format].to_s.to_sym : :iso,
        amount_format: params[:amount_format].to_s == "comma" ? :comma : :point,
        no_header: params[:no_header] == "1",
        swap: params[:swap] == "1",
        include_before_start: params[:include_before_start] != "0"
      }
      file = params[:file]
      if !file.respond_to?(:size) || file.size.zero?
        @result = CsvImport::Result.new(rows: [], problems: [ CsvImport::Problem.new(nil, "Choose a CSV file") ], mapping: {})
        return render :show, status: :unprocessable_entity
      end
      if file.size > CsvImport::MAX_BYTES
        @result = CsvImport::Result.new(rows: [], problems: [ CsvImport::Problem.new(nil, "The file is larger than #{CsvImport::MAX_BYTES} bytes and was not read") ], mapping: {})
        return render :show, status: :unprocessable_entity
      end
      @filename = File.basename(file.original_filename.to_s)
      data = file.read.to_s
      @result = CsvImport.plan(data, account: @account, **@settings)
      @header = @settings[:no_header] ? nil : CsvImport.records(data.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("\uFEFF")).first
      render :show
    end

    private
      def set_budget
        @budget = Current.user.budgets.find_by!(public_id: params[:budget_public_id])
      end

      def set_account
        @account = @budget.accounts.not_deleted.find_by!(public_id: params[:account_public_id])
      end

      def milliunits_text(value)
        amount = value.to_i
        format("%s$%.2f", amount.negative? ? "-" : "", amount.abs / 1000.0)
      end
      helper_method :milliunits_text
  end
end
