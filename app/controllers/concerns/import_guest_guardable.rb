# The import wizard's steps change an import before it is published. Guests
# may only change their own kind of import, and only before publishing. No one
# may change an import whose configuration is locked.
module ImportGuestGuardable
  extend ActiveSupport::Concern

  private
    # Imports are family-scoped, but their rows are bound for specific
    # accounts, so they are closed to members who cannot see those accounts
    # or the statement the import was read from.
    def require_import_account_access!
      raise ActiveRecord::RecordNotFound unless @import.visible_to?(Current.user)
    end

    def require_import_editable!
      return require_non_guest! unless @import.editable_by?(Current.user)

      redirect_to import_path(@import), alert: t("imports.configuration_locked") if @import.configuration_locked?
    end
end
