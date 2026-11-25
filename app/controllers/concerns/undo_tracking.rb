# Undo and Redo history scope for the signed-in session (Undo slice 1).
# The history belongs to one user, plan, sign-in session and page-load token.
# A request that is not a Turbo visit (a reload, a typed address, a new tab)
# starts a new token and drops the older history, so Undo and Redo are
# disabled after a page reload, as in the reference.
module UndoTracking
  extend ActiveSupport::Concern

  included do
    before_action :rotate_undo_token, if: :document_load?
    helper_method :undo_history
  end

  private
    def document_load?
      request.get? && request.format.html? && request.headers["X-Turbo-Request-Id"].blank?
    end

    def rotate_undo_token
      return unless Current.session

      session[:undo_token] = SecureRandom.hex(8)
      UndoStep.where(session_key: Current.session.id.to_s).where.not(token: session[:undo_token]).delete_all
    end

    def undo_history
      return unless Current.session && @budget

      session[:undo_token] ||= SecureRandom.hex(8)
      @undo_history ||= UndoHistory.new(user: Current.user, budget: @budget, session_key: Current.session.id, token: session[:undo_token])
    end

    # Keeps the history notice (for example "history was cleared") for the next page.
    def announce_undo_notice
      flash[:undo_status] = undo_history.notice if undo_history&.notice
    end
end
